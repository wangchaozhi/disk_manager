import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart'; 
import 'package:cached_network_image/cached_network_image.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'video_preview.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Disk Manager',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const FileManagerPage(),
    );
  }
}

class FileManagerPage extends StatefulWidget {
  const FileManagerPage({super.key});

  @override
  State<FileManagerPage> createState() => _FileManagerPageState();
}

class _FileManagerPageState extends State<FileManagerPage> {
  List<dynamic> _files = [];
  bool _isLoading = false;
  
  // Track current directory stack
  final List<String> _pathStack = [];
  
  String get _currentPath => _pathStack.join('/');

  // On Web, localhost is typically fine if requesting from same origin or localhost:3000
  // On Android Emulator, use 10.0.2.2
  // On Desktop/iOS Sim, use 127.0.0.1
  String get _baseUrl {
    if (kIsWeb) return 'http://127.0.0.1:3000';
    if (defaultTargetPlatform == TargetPlatform.android) return 'http://10.0.2.2:3000';
    return 'http://127.0.0.1:3000';
  }

  @override
  void initState() {
    super.initState();
    _fetchFiles();
  }
  
  Future<void> _fetchFiles() async {
    setState(() => _isLoading = true);
    try {
      final pathParam = _currentPath.isNotEmpty ? '?path=$_currentPath' : '';
      final response = await http.get(Uri.parse('$_baseUrl/list$pathParam'));
      
      if (response.statusCode == 200) {
        setState(() {
          _files = jsonDecode(response.body);
        });
      } else {
        _showError('Failed to load files: ${response.statusCode}');
      }
    } catch (e) {
      _showError('Error connecting to server: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _navigateToFolder(String folderName) {
    _pathStack.add(folderName);
    _fetchFiles();
  }

  void _navigateUp() {
    if (_pathStack.isNotEmpty) {
      _pathStack.removeLast();
      _fetchFiles();
    }
  }

  Future<void> _createFolder() async {
    final TextEditingController controller = TextEditingController();
    final String? folderName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Folder'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Folder Name'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (folderName != null && folderName.isNotEmpty) {
      try {
        final path = _currentPath.isEmpty ? folderName : '$_currentPath/$folderName';
        
        final response = await http.post(
          Uri.parse('$_baseUrl/create_folder'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'path': path}),
        );
        
        if (response.statusCode == 200) {
          _fetchFiles();
          _showSnack('Folder created');
        } else {
          _showError('Failed to create folder: ${response.body}');
        }
      } catch (e) {
        _showError('Error: $e');
      }
    }
  }

  Future<void> _uploadFile() async {
    // Picking logic handles web/mobile differently under the hood
    FilePickerResult? result = await FilePicker.platform.pickFiles();

    if (result != null) {
      final file = result.files.single;
       
       final pathParam = _currentPath.isNotEmpty ? '?path=$_currentPath' : '';
       var uri = Uri.parse('$_baseUrl/upload$pathParam');

        var request = http.MultipartRequest('POST', uri);
        
        // On Web, path is null, bytes are populated.
        // On Mobile/Desktop, path is populated (usually).
        if (file.bytes != null) {
             request.files.add(http.MultipartFile.fromBytes('file', file.bytes!, filename: file.name));
        } else if (file.path != null) {
            request.files.add(await http.MultipartFile.fromPath('file', file.path!));
        }

        try {
          var response = await request.send();
          if (response.statusCode == 200) {
            _fetchFiles();
             _showSnack('File uploaded');
          } else {
             _showError('Upload failed: ${response.statusCode}');
          }
        } catch (e) {
             _showError('Error uploading: $e');
        }

    }
  }
  
  Future<void> _downloadFile(String fileName) async {
       try {
         final path = _currentPath.isEmpty ? fileName : '$_currentPath/$fileName';
         final url = '$_baseUrl/download?path=$path';
         
         final uri = Uri.parse(url);
         if (await canLaunchUrl(uri)) {
           await launchUrl(uri, mode: LaunchMode.externalApplication);
         } else {
           _showError('Could not launch download url');
         }
       } catch (e) {
         _showError('Download Error: $e');
       }
  }

  Future<void> _deleteFile(String fileName) async {
    try {
      final path = _currentPath.isEmpty ? fileName : '$_currentPath/$fileName';
      final url = '$_baseUrl/delete?path=$path';
      
      final response = await http.delete(Uri.parse(url));
      
      if (response.statusCode == 200) {
        _fetchFiles();
        _showSnack('Deleted successfully');
      } else {
        _showError('Delete failed: ${response.statusCode}');
      }
    } catch (e) {
      _showError('Delete Error: $e');
    }
  }

  void _previewFile(String fileName) {
    final path = _currentPath.isEmpty ? fileName : '$_currentPath/$fileName';
    final url = '$_baseUrl/download?path=$path';
    final extension = fileName.split('.').last.toLowerCase();

    if (['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(extension)) {
      showDialog(
        context: context,
        builder: (context) => Dialog(
          child: CachedNetworkImage(
            imageUrl: url,
            placeholder: (context, url) => const CircularProgressIndicator(),
            errorWidget: (context, url, error) => const Icon(Icons.error),
          ),
        ),
      );
    } else if (['mp4', 'mov', 'avi', 'mkv'].contains(extension)) {
      // Video Preview
      showDialog(
        context: context,
        builder: (context) => VideoPreviewDialog(url: url),
      );
    } else if (['txt', 'md', 'json', 'xml', 'log'].contains(extension)) {
       // Text Preview
       showDialog(
         context: context,
         builder: (context) => FutureBuilder<http.Response>(
           future: http.get(Uri.parse(url)),
           builder: (context, snapshot) {
             if (snapshot.hasData) {
               return AlertDialog(
                 title: Text(fileName),
                 content: SingleChildScrollView(child: Text(snapshot.data!.body)),
                 actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
               );
             } else if (snapshot.hasError) {
               return AlertDialog(title: const Text('Error'), content: Text('${snapshot.error}'));
             }
             return const Center(child: CircularProgressIndicator());
           },
         )
       );
    } else {
      _showSnack('Preview not supported for this file type');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: Colors.red,
    ));
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_currentPath.isEmpty ? 'Disk Manager' : _currentPath),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        leading: _pathStack.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _navigateUp,
              )
            : null,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchFiles,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
              ? const Center(child: Text('Empty folder'))
              : ListView.builder(
                  itemCount: _files.length,
                  itemBuilder: (context, index) {
                    final file = _files[index];
                    final isDir = file['is_dir'] ?? false;
                    final name = file['name'] ?? 'Unknown';
                    
                    return ListTile(
                      leading: Icon(isDir ? Icons.folder : Icons.insert_drive_file, 
                        color: isDir ? Colors.amber : Colors.blueGrey),
                      title: Text(name),
                      onTap: () {
                        if (isDir) {
                          _navigateToFolder(name);
                        } else {
                          _previewFile(name);
                        }
                      },
                      onLongPress: () {
                         showDialog(
                           context: context, 
                           builder: (context) => AlertDialog(
                             title: Text('Options for "$name"'),
                             actions: [
                               TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                               TextButton(onPressed: () {
                                 Navigator.pop(context);
                                 _deleteFile(name);
                               }, child: const Text('Delete', style: TextStyle(color: Colors.red))),
                               TextButton(onPressed: () {
                                 Navigator.pop(context);
                                 _downloadFile(name);
                               }, child: const Text('Download')),
                             ],
                           )
                         );
                      },
                    );
                  },
                ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            heroTag: 'upload',
            onPressed: _uploadFile,
            tooltip: 'Upload File',
            child: const Icon(Icons.upload_file),
          ),
          const SizedBox(height: 16),
          FloatingActionButton(
            heroTag: 'create_folder',
            onPressed: _createFolder,
            tooltip: 'Create Folder',
            child: const Icon(Icons.create_new_folder),
          ),
        ],
      ),
    );
  }
}
