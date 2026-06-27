import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:signature/signature.dart';

void main() {
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
  final List<String> _guards = ['Guard A', 'Guard B', 'Guard C'];

  // Signature
  final SignatureController _signatureController = SignatureController(
    penStrokeWidth: 3,
    penColor: Colors.black,
    exportBackgroundColor: Colors.white,
  );

  @override
  void initState() {
    super.initState();
    // Initialize with current date and time
    final now = DateTime.now();
    _dateController.text = DateFormat('dd-MMM-yy').format(now);
    _timeController.text = DateFormat('HH:mm').format(now);
  }

  @override
  void dispose() {
    _dateController.dispose();
    _timeController.dispose();
    _vendorNameController.dispose();
    _vehicleNumberController.dispose();
    _signatureController.dispose();
    super.dispose();
  }

  Future<void> _pickImage(String type) async {
    final XFile? image = await _picker.pickImage(source: ImageSource.camera);
    if (image != null) {
      setState(() {
        if (type == 'side') _sidePic = image;
        if (type == 'back') _backPic = image;
        if (type == 'top') _topPic = image;
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

  void _submitData() {
    // Here we would eventually send the data to the backend.
    // For now, just show a success message and clear the form.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Data saved successfully!')),
    );
    _clearForm();
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
                ? Image.file(File(file.path), fit: BoxFit.cover)
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
            const SizedBox(height: 20),

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
              onPressed: _showVerifyDialog,
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
