import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:signature/signature.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Water Tanker Logger',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const DataLoggingScreen(),
    );
  }
}

class DataLoggingScreen extends StatefulWidget {
  const DataLoggingScreen({super.key});

  @override
  State<DataLoggingScreen> createState() => _DataLoggingScreenState();
}

class _DataLoggingScreenState extends State<DataLoggingScreen> {
  final _formKey = GlobalKey<FormState>();

  // Image Pickers
  final ImagePicker _picker = ImagePicker();
  XFile? _sidePic;
  XFile? _backPic;
  XFile? _topPic;

  // Controllers
  final TextEditingController _dateController = TextEditingController();
  final TextEditingController _timeController = TextEditingController();
  final TextEditingController _vendorNameController = TextEditingController();
  final TextEditingController _vehicleNumberController = TextEditingController();

  // Dropdown states
  String? _selectedCapacity;
  String? _selectedGuard;

  final List<String> _capacities = ['12K', '24K'];
  List<String> _guards = ['Guard A', 'Guard B', 'Guard C'];

  // Signature
  final SignatureController _signatureController = SignatureController(
    penStrokeWidth: 3,
    penColor: Colors.black,
    exportBackgroundColor: Colors.white,
  );

  bool _isAnalyzing = false;
  bool _isUploading = false;

  // Offline Caching & WebSocket connection state
  Database? _queueDb;
  List<Map<String, dynamic>> _webQueue = [];
  late StreamSubscription<ConnectivityResult> _connectivitySubscription;
  WebSocketChannel? _wsChannel;
  Timer? _reconnectTimer;

  @override
  void initState() {
    super.initState();
    // Initialize with current date and time
    final now = DateTime.now();
    _dateController.text = DateFormat('dd-MMM-yy').format(now);
    _timeController.text = DateFormat('HH:mm').format(now);

    // Initializations
    _initQueueDb();
    _loadCachedGuards();
    _fetchGuardsHttp();
    _initWebSocket();
    _setupConnectivityListener();
  }

  @override
  void dispose() {
    _dateController.dispose();
    _timeController.dispose();
    _vendorNameController.dispose();
    _vehicleNumberController.dispose();
    _signatureController.dispose();
    _connectivitySubscription.cancel();
    _wsChannel?.sink.close();
    _reconnectTimer?.cancel();
    super.dispose();
  }

  // Local SQLite Queue setup (SharedPreferences on Web)
  Future<void> _initQueueDb() async {
    if (kIsWeb) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final queueJson = prefs.getString('offline_queue_web') ?? '[]';
        final List<dynamic> decoded = jsonDecode(queueJson);
        _webQueue = decoded.map((e) => Map<String, dynamic>.from(e)).toList();
        _processQueue();
      } catch (e) {
        debugPrint('Failed to load web offline queue: $e');
      }
      return;
    }
    try {
      final databasesPath = await getDatabasesPath();
      final dbPath = path.join(databasesPath, 'offline_queue.db');

      _queueDb = await openDatabase(
        dbPath,
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE queued_logs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              log_date TEXT,
              in_time TEXT,
              vendor_name TEXT,
              vehicle_number TEXT,
              capacity TEXT,
              security_guard TEXT,
              side_pic_path TEXT,
              back_pic_path TEXT,
              top_pic_path TEXT,
              signature_path TEXT,
              status TEXT DEFAULT 'pending'
            )
          ''');
        },
      );
      
      // Process queue on startup in case there are unsynced items
      _processQueue();
    } catch (e) {
      debugPrint('Failed to initialize local SQLite queue: $e');
    }
  }

  // Load cache key-value store for guards list
  Future<void> _loadCachedGuards() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getStringList('cached_guards');
    if (cached != null && cached.isNotEmpty) {
      setState(() {
        _guards = cached;
      });
    }
  }

  // Fetch guard details via standard HTTP get on startup
  Future<void> _fetchGuardsHttp() async {
    final backendUrl = dotenv.env['BACKEND_URL'] ?? 'http://10.0.2.2:8080';
    try {
      final response = await http.get(Uri.parse('$backendUrl/api/settings/guards')).timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        final List<dynamic> list = jsonDecode(response.body);
        final List<String> fetchedGuards = list.map((e) => e.toString()).toList();
        if (fetchedGuards.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setStringList('cached_guards', fetchedGuards);
          setState(() {
            _guards = fetchedGuards;
          });
        }
      }
    } catch (e) {
      debugPrint('HTTP guards fetch failed, falling back to local cache: $e');
    }
  }

  // Connect to persistent WebSocket for instant settings updates
  void _initWebSocket() {
    final backendUrl = dotenv.env['BACKEND_URL'] ?? 'http://10.0.2.2:8080';
    final wsUrl = backendUrl.replaceFirst('http://', 'ws://').replaceFirst('https://', 'wss://') + '/api/settings/guards/ws';

    try {
      _wsChannel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _wsChannel!.stream.listen(
        (message) async {
          try {
            final List<dynamic> list = jsonDecode(message);
            final List<String> fetchedGuards = list.map((e) => e.toString()).toList();
            if (fetchedGuards.isNotEmpty) {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setStringList('cached_guards', fetchedGuards);
              setState(() {
                _guards = fetchedGuards;
                if (_selectedGuard != null && !_guards.contains(_selectedGuard)) {
                  _selectedGuard = null; // reset if selected guard was removed
                }
              });
            }
          } catch (e) {
            debugPrint('Failed to parse WebSocket message: $e');
          }
        },
        onError: (err) {
          debugPrint('WebSocket error encountered: $err');
          _reconnectWebSocket();
        },
        onDone: () {
          debugPrint('WebSocket stream completed.');
          _reconnectWebSocket();
        },
      );
    } catch (e) {
      debugPrint('Failed to initiate WebSocket connection: $e');
      _reconnectWebSocket();
    }
  }

  void _reconnectWebSocket() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) {
        debugPrint('Reconnecting WebSocket...');
        _initWebSocket();
      }
    });
  }

  // Setup connection state listener
  void _setupConnectivityListener() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((dynamic result) {
      ConnectivityResult res;
      if (result is List) {
        res = result.isNotEmpty ? result.first : ConnectivityResult.none;
      } else {
        res = result as ConnectivityResult;
      }
      if (res != ConnectivityResult.none) {
        debugPrint('Connectivity restored. Syncing offline logs...');
        _processQueue();
      }
    });
  }

  Future<void> _pickImage(String type) async {
    final XFile? image = await _picker.pickImage(source: ImageSource.camera);
    if (image != null) {
      setState(() {
        if (type == 'side') _sidePic = image;
        if (type == 'back') _backPic = image;
        if (type == 'top') _topPic = image;
      });

      // Analyze the image to extract data if it's back or side pic
      if (type == 'back' || type == 'side') {
        _extractInfoFromImage(image);
      }
    }
  }

  Future<void> _extractInfoFromImage(XFile image) async {
    final apiKey = dotenv.env['GEMINI_API_KEY'];
    if (apiKey == null || apiKey.isEmpty || apiKey == 'YOUR_GEMINI_API_KEY_HERE') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Gemini API Key is missing or invalid.')),
      );
      return;
    }

    setState(() {
      _isAnalyzing = true;
    });

    try {
      final model = GenerativeModel(
        model: 'gemini-2.5-flash',
        apiKey: apiKey,
      );

      final imageBytes = await image.readAsBytes();
      final prompt = TextPart(
          'Extract the vehicle registration number and vendor/company name from this image if visible. '
          'Return ONLY a raw JSON object with keys "vehicleNumber" and "vendorName". '
          'Do not include markdown blocks like ```json.');
      final imagePart = DataPart('image/jpeg', imageBytes);

      final response = await model.generateContent([
        Content.multi([prompt, imagePart])
      ]);

      if (response.text != null) {
        try {
          final jsonStr = response.text!.trim().replaceAll('```json', '').replaceAll('```', '');
          final Map<String, dynamic> data = jsonDecode(jsonStr);

          setState(() {
            if (data.containsKey('vehicleNumber') && data['vehicleNumber'] != null) {
              _vehicleNumberController.text = data['vehicleNumber'].toString();
            }
            if (data.containsKey('vendorName') && data['vendorName'] != null) {
              _vendorNameController.text = data['vendorName'].toString();
            }
          });
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Image analyzed successfully!')),
          );
        } catch (e) {
          debugPrint('Failed to parse JSON: $e');
        }
      }
    } catch (e) {
      debugPrint('Error analyzing image: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to analyze image.')),
      );
    } finally {
      setState(() {
        _isAnalyzing = false;
      });
    }
  }

  Future<void> _selectDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2101),
    );
    if (picked != null) {
      setState(() {
        _dateController.text = DateFormat('dd-MMM-yy').format(picked);
      });
    }
  }

  Future<void> _selectTime() async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (picked != null) {
      setState(() {
        final now = DateTime.now();
        final dt = DateTime(now.year, now.month, now.day, picked.hour, picked.minute);
        _timeController.text = DateFormat('HH:mm').format(dt);
      });
    }
  }

  void _showVerifyDialog() {
    if (_formKey.currentState!.validate()) {
      showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Verify Data'),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Date: ${_dateController.text}'),
                  Text('In Time: ${_timeController.text}'),
                  Text('Vendor Name: ${_vendorNameController.text}'),
                  Text('Vehicle Number: ${_vehicleNumberController.text}'),
                  Text('Capacity: $_selectedCapacity'),
                  Text('Security Guard: ${_selectedGuard ?? "Not selected"}'),
                  const SizedBox(height: 10),
                  Text('Photos Captured:'),
                  Text('- Side Pic: ${_sidePic != null ? "Yes" : "No"}'),
                  Text('- Back Pic: ${_backPic != null ? "Yes" : "No"}'),
                  Text('- Top Pic: ${_topPic != null ? "Yes" : "No"}'),
                  const SizedBox(height: 10),
                  Text('Signature Captured: ${_signatureController.isNotEmpty ? "Yes" : "No"}'),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Edit / Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  _submitData();
                },
                child: const Text('Confirm & Submit'),
              ),
            ],
          );
        },
      );
    }
  }

  Future<void> _submitData() async {
    setState(() {
      _isUploading = true;
    });

    final dynamic connectivityResult = await Connectivity().checkConnectivity();
    ConnectivityResult res;
    if (connectivityResult is List) {
      res = connectivityResult.isNotEmpty ? (connectivityResult as List).first : ConnectivityResult.none;
    } else {
      res = connectivityResult as ConnectivityResult;
    }

    if (res == ConnectivityResult.none) {
      // Offline mode: cache data
      await _queueLogLocally();
      setState(() {
        _isUploading = false;
      });
      return;
    }

    // Load photo and signature bytes directly (avoids fromPath on Web)
    List<int>? sideBytes;
    List<int>? backBytes;
    List<int>? topBytes;
    List<int>? sigBytes;

    try {
      if (_sidePic != null) sideBytes = await _sidePic!.readAsBytes();
      if (_backPic != null) backBytes = await _backPic!.readAsBytes();
      if (_topPic != null) topBytes = await _topPic!.readAsBytes();
      sigBytes = await _signatureController.toPngBytes();
    } catch (e) {
      debugPrint('Failed to read image bytes: $e');
    }

    // Try direct upload
    final success = await _uploadToServer(
      date: _dateController.text,
      inTime: _timeController.text,
      vendorName: _vendorNameController.text,
      vehicleNumber: _vehicleNumberController.text,
      capacity: _selectedCapacity!,
      securityGuard: _selectedGuard,
      sidePicPath: null,
      backPicPath: null,
      topPicPath: null,
      signatureController: _signatureController,
      preloadedSigBytes: sigBytes,
      preloadedSideBytes: sideBytes,
      preloadedBackBytes: backBytes,
      preloadedTopBytes: topBytes,
    );

    if (success) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Data uploaded successfully!')),
        );
        _clearForm();
      }
    } else {
      // Direct upload failed, queue locally
      await _queueLogLocally();
    }

    if (mounted) {
      setState(() {
        _isUploading = false;
      });
    }
  }

  // Backup files persistently and record log details in SQLite (or SharedPreferences on Web)
  Future<void> _queueLogLocally() async {
    if (kIsWeb) {
      try {
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final logItem = {
          'id': timestamp,
          'log_date': _dateController.text,
          'in_time': _timeController.text,
          'vendor_name': _vendorNameController.text,
          'vehicle_number': _vehicleNumberController.text,
          'capacity': _selectedCapacity,
          'security_guard': _selectedGuard,
          'status': 'pending',
        };

        // Convert files to base64 for persistent localStorage on Web
        if (_sidePic != null) {
          final bytes = await _sidePic!.readAsBytes();
          logItem['side_pic_base64'] = base64Encode(bytes);
        }
        if (_backPic != null) {
          final bytes = await _backPic!.readAsBytes();
          logItem['back_pic_base64'] = base64Encode(bytes);
        }
        if (_topPic != null) {
          final bytes = await _topPic!.readAsBytes();
          logItem['top_pic_base64'] = base64Encode(bytes);
        }

        final sigBytes = await _signatureController.toPngBytes();
        if (sigBytes != null) {
          logItem['signature_base64'] = base64Encode(sigBytes);
        }

        _webQueue.add(logItem);

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('offline_queue_web', jsonEncode(_webQueue));

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Offline: Log queued locally (localStorage)!')),
          );
          _clearForm();
        }
      } catch (e) {
        debugPrint('Failed to queue log locally on Web: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to save log locally.')),
          );
        }
      }
      return;
    }

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final backupDir = Directory(path.join(appDir.path, 'queued_photos'));
      await backupDir.create(recursive: true);

      String? sidePath;
      String? backPath;
      String? topPath;
      String? sigPath;

      final timestamp = DateTime.now().millisecondsSinceEpoch;

      if (_sidePic != null) {
        sidePath = path.join(backupDir.path, '$timestamp-side.jpg');
        await File(_sidePic!.path).copy(sidePath);
      }
      if (_backPic != null) {
        backPath = path.join(backupDir.path, '$timestamp-back.jpg');
        await File(_backPic!.path).copy(backPath);
      }
      if (_topPic != null) {
        topPath = path.join(backupDir.path, '$timestamp-top.jpg');
        await File(_topPic!.path).copy(topPath);
      }

      final sigBytes = await _signatureController.toPngBytes();
      if (sigBytes != null) {
        sigPath = path.join(backupDir.path, '$timestamp-sig.png');
        await File(sigPath).writeAsBytes(sigBytes);
      }

      if (_queueDb != null) {
        await _queueDb!.insert('queued_logs', {
          'log_date': _dateController.text,
          'in_time': _timeController.text,
          'vendor_name': _vendorNameController.text,
          'vehicle_number': _vehicleNumberController.text,
          'capacity': _selectedCapacity,
          'security_guard': _selectedGuard,
          'side_pic_path': sidePath,
          'back_pic_path': backPath,
          'top_pic_path': topPath,
          'signature_path': sigPath,
          'status': 'pending',
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Offline: Log queued successfully!')),
        );
        _clearForm();
      }
    } catch (e) {
      debugPrint('Failed to queue log locally: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to save log locally.')),
        );
      }
    }
  }

  // Challenge-response upload helper
  Future<bool> _uploadToServer({
    required String date,
    required String inTime,
    required String vendorName,
    required String vehicleNumber,
    required String capacity,
    required String? securityGuard,
    required String? sidePicPath,
    required String? backPicPath,
    required String? topPicPath,
    required SignatureController signatureController,
    List<int>? preloadedSigBytes,
    List<int>? preloadedSideBytes,
    List<int>? preloadedBackBytes,
    List<int>? preloadedTopBytes,
  }) async {
    final backendUrl = dotenv.env['BACKEND_URL'] ?? 'http://10.0.2.2:8080';
    final appSecret = dotenv.env['APP_SECRET'] ?? 'default_shared_app_secret';

    try {
      // 1. Fetch challenge nonce
      final challengeUrl = Uri.parse('$backendUrl/api/auth/challenge');
      final challengeResponse = await http.get(challengeUrl).timeout(const Duration(seconds: 4));
      if (challengeResponse.statusCode != 200) {
        return false;
      }
      
      final challengeData = jsonDecode(challengeResponse.body);
      final challenge = challengeData['challenge'] as String;

      // 2. Compute response: SHA256(challenge + APP_SECRET)
      final bytesToHash = utf8.encode(challenge + appSecret);
      final responseHash = sha256.convert(bytesToHash).toString();

      // 3. Construct Multipart POST
      final uploadUrl = Uri.parse('$backendUrl/api/tanker-logs');
      final request = http.MultipartRequest('POST', uploadUrl);

      // Add Headers
      request.headers['X-Challenge'] = challenge;
      request.headers['X-Response'] = responseHash;

      // Add Text fields
      request.fields['date'] = date;
      request.fields['inTime'] = inTime;
      request.fields['vendorName'] = vendorName;
      request.fields['vehicleNumber'] = vehicleNumber;
      request.fields['capacity'] = capacity;
      if (securityGuard != null) {
        request.fields['securityGuard'] = securityGuard;
      }

      // Add Files (supports preloaded bytes directly for Web compatibility)
      if (preloadedSideBytes != null) {
        request.files.add(http.MultipartFile.fromBytes('sidePic', preloadedSideBytes, filename: 'side.jpg'));
      } else if (sidePicPath != null && sidePicPath.isNotEmpty) {
        request.files.add(await http.MultipartFile.fromPath('sidePic', sidePicPath));
      }

      if (preloadedBackBytes != null) {
        request.files.add(http.MultipartFile.fromBytes('backPic', preloadedBackBytes, filename: 'back.jpg'));
      } else if (backPicPath != null && backPicPath.isNotEmpty) {
        request.files.add(await http.MultipartFile.fromPath('backPic', backPicPath));
      }

      if (preloadedTopBytes != null) {
        request.files.add(http.MultipartFile.fromBytes('topPic', preloadedTopBytes, filename: 'top.jpg'));
      } else if (topPicPath != null && topPicPath.isNotEmpty) {
        request.files.add(await http.MultipartFile.fromPath('topPic', topPicPath));
      }

      // Add signature bytes
      if (preloadedSigBytes != null) {
        request.files.add(http.MultipartFile.fromBytes(
          'signature',
          preloadedSigBytes,
          filename: 'signature.png',
        ));
      } else {
        final sigBytes = await signatureController.toPngBytes();
        if (sigBytes == null) return false;
        request.files.add(http.MultipartFile.fromBytes(
          'signature',
          sigBytes,
          filename: 'signature.png',
        ));
      }

      final streamResponse = await request.send().timeout(const Duration(seconds: 15));
      if (streamResponse.statusCode == 201) {
        return true;
      }
    } catch (e) {
      debugPrint('HTTP upload to server failed: $e');
    }
    return false;
  }

  // Background queue processing
  bool _isSyncing = false;
  Future<void> _processQueue() async {
    if (_isSyncing) return;

    if (kIsWeb) {
      _isSyncing = true;
      try {
        final pending = _webQueue.where((item) => item['status'] == 'pending').toList();
        if (pending.isEmpty) {
          _isSyncing = false;
          return;
        }

        debugPrint('Syncing ${pending.length} logs from web offline queue...');

        for (var item in pending) {
          item['status'] = 'uploading';

          final date = item['log_date'] as String;
          final inTime = item['in_time'] as String;
          final vendorName = item['vendor_name'] as String;
          final vehicleNumber = item['vehicle_number'] as String;
          final capacity = item['capacity'] as String;
          final securityGuard = item['security_guard'] as String?;

          List<int>? sideBytes;
          List<int>? backBytes;
          List<int>? topBytes;
          List<int>? sigBytes;

          if (item['side_pic_base64'] != null) {
            sideBytes = base64Decode(item['side_pic_base64']);
          }
          if (item['back_pic_base64'] != null) {
            backBytes = base64Decode(item['back_pic_base64']);
          }
          if (item['top_pic_base64'] != null) {
            topBytes = base64Decode(item['top_pic_base64']);
          }
          if (item['signature_base64'] != null) {
            sigBytes = base64Decode(item['signature_base64']);
          }

          final success = await _uploadToServer(
            date: date,
            inTime: inTime,
            vendorName: vendorName,
            vehicleNumber: vehicleNumber,
            capacity: capacity,
            securityGuard: securityGuard,
            sidePicPath: null,
            backPicPath: null,
            topPicPath: null,
            signatureController: _signatureController,
            preloadedSigBytes: sigBytes,
            preloadedSideBytes: sideBytes,
            preloadedBackBytes: backBytes,
            preloadedTopBytes: topBytes,
          );

          if (success) {
            _webQueue.removeWhere((x) => x['id'] == item['id']);
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('offline_queue_web', jsonEncode(_webQueue));
            debugPrint('Successfully synced web offline log: ${item['id']}');
            
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Offline log for $vendorName ($date) synced successfully!')),
              );
            }
          } else {
            item['status'] = 'pending';
            break; // Stop syncing queue if connection fails
          }
        }
      } catch (e) {
        debugPrint('Error syncing web offline queue: $e');
      } finally {
        _isSyncing = false;
      }
      return;
    }

    if (_queueDb == null) return;
    _isSyncing = true;

    try {
      final List<Map<String, dynamic>> pending = await _queueDb!.query(
        'queued_logs',
        where: "status = 'pending'",
        orderBy: 'id ASC',
      );

      if (pending.isEmpty) {
        _isSyncing = false;
        return;
      }

      debugPrint('Syncing ${pending.length} logs from the offline queue...');

      for (var row in pending) {
        final id = row['id'] as int;

        // Mark as uploading to prevent concurrent triggers
        await _queueDb!.update(
          'queued_logs',
          {'status': 'uploading'},
          where: 'id = ?',
          whereArgs: [id],
        );

        final date = row['log_date'] as String;
        final inTime = row['in_time'] as String;
        final vendorName = row['vendor_name'] as String;
        final vehicleNumber = row['vehicle_number'] as String;
        final capacity = row['capacity'] as String;
        final securityGuard = row['security_guard'] as String?;
        final sidePath = row['side_pic_path'] as String?;
        final backPath = row['back_pic_path'] as String?;
        final topPath = row['top_pic_path'] as String?;
        final sigPath = row['signature_path'] as String?;

        List<int>? sigBytes;
        if (sigPath != null) {
          sigBytes = await File(sigPath).readAsBytes();
        }

        final success = await _uploadToServer(
          date: date,
          inTime: inTime,
          vendorName: vendorName,
          vehicleNumber: vehicleNumber,
          capacity: capacity,
          securityGuard: securityGuard,
          sidePicPath: sidePath,
          backPicPath: backPath,
          topPicPath: topPath,
          signatureController: _signatureController,
          preloadedSigBytes: sigBytes,
        );

        if (success) {
          // Sync complete: Delete SQLite row
          await _queueDb!.delete(
            'queued_logs',
            where: 'id = ?',
            whereArgs: [id],
          );

          // Clean local persistent backup files
          if (sidePath != null) await _deleteFile(sidePath);
          if (backPath != null) await _deleteFile(backPath);
          if (topPath != null) await _deleteFile(topPath);
          if (sigPath != null) await _deleteFile(sigPath);

          debugPrint('Successfully synced offline log: $id');

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Offline log for $vendorName ($date) synced successfully!')),
            );
          }
        } else {
          // Failed: Revert to pending
          await _queueDb!.update(
            'queued_logs',
            {'status': 'pending'},
            where: 'id = ?',
            whereArgs: [id],
          );
          break; // Stop syncing queue if network is failing again
        }
      }
    } catch (e) {
      debugPrint('Error syncing offline queue: $e');
    } finally {
      _isSyncing = false;
    }
  }

  Future<void> _deleteFile(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('Failed to delete cached photo file: $e');
    }
  }

  void _clearForm() {
    setState(() {
      _sidePic = null;
      _backPic = null;
      _topPic = null;
      _vendorNameController.clear();
      _vehicleNumberController.clear();
      _selectedCapacity = null;
      _selectedGuard = null;
      _signatureController.clear();
      
      final now = DateTime.now();
      _dateController.text = DateFormat('dd-MMM-yy').format(now);
      _timeController.text = DateFormat('HH:mm').format(now);
    });
  }

  Widget _buildPhotoPicker(String label, XFile? file, String type) {
    return Column(
      children: [
        Text(label),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () => _pickImage(type),
          child: Container(
            width: 100,
            height: 100,
            color: Colors.grey[300],
            child: file != null
                ? (kIsWeb
                    ? Image.network(file.path, fit: BoxFit.cover)
                    : Image.file(File(file.path), fit: BoxFit.cover))
                : const Icon(Icons.camera_alt, size: 40),
          ),
        ),
        if (file != null)
          TextButton(
            onPressed: () => _pickImage(type),
            child: const Text('Retake'),
          )
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Water Tanker Logger'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            // Photos Section
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildPhotoPicker('Side Pic', _sidePic, 'side'),
                _buildPhotoPicker('Back Pic', _backPic, 'back'),
                _buildPhotoPicker('Top Pic', _topPic, 'top'),
              ],
            ),
            const SizedBox(height: 10),
            
            if (_isAnalyzing)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Column(
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 8),
                      Text('Analyzing image...'),
                    ],
                  ),
                ),
              ),

            if (_isUploading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Column(
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 8),
                      Text('Uploading log...'),
                    ],
                  ),
                ),
              ),

            const SizedBox(height: 10),

            // Form Fields
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _dateController,
                    decoration: const InputDecoration(labelText: 'Date'),
                    readOnly: true,
                    onTap: _selectDate,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: _timeController,
                    decoration: const InputDecoration(labelText: 'In Time'),
                    readOnly: true,
                    onTap: _selectTime,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            TextFormField(
              controller: _vendorNameController,
              decoration: const InputDecoration(labelText: 'Name of the Vendor'),
              validator: (value) => value!.isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 16),
            
            TextFormField(
              controller: _vehicleNumberController,
              decoration: const InputDecoration(labelText: 'Vehicle Number'),
              validator: (value) => value!.isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 16),
            
            DropdownButtonFormField<String>(
              decoration: const InputDecoration(labelText: 'Capacity'),
              value: _selectedCapacity,
              items: _capacities.map((String value) {
                return DropdownMenuItem<String>(
                  value: value,
                  child: Text(value),
                );
              }).toList(),
              onChanged: (newValue) {
                setState(() {
                  _selectedCapacity = newValue;
                });
              },
              validator: (value) => value == null ? 'Required' : null,
            ),
            const SizedBox(height: 16),
            
            DropdownButtonFormField<String>(
              decoration: const InputDecoration(labelText: 'Security Guard Name (Optional)'),
              value: _selectedGuard,
              items: _guards.map((String value) {
                return DropdownMenuItem<String>(
                  value: value,
                  child: Text(value),
                );
              }).toList(),
              onChanged: (newValue) {
                setState(() {
                  _selectedGuard = newValue;
                });
              },
            ),
            const SizedBox(height: 20),
            
            // Signature Section
            const Text('Signature of driver', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(border: Border.all(color: Colors.blueAccent)),
              child: Signature(
                controller: _signatureController,
                height: 150,
                backgroundColor: Colors.blue[50]!,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => _signatureController.clear(),
                child: const Text('Clear Signature'),
              ),
            ),
            const SizedBox(height: 20),
            
            ElevatedButton(
              onPressed: _isUploading ? null : _showVerifyDialog,
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 50),
              ),
              child: const Text('Verify & Submit', style: TextStyle(fontSize: 18)),
            ),
          ],
        ),
      ),
    );
  }
}
