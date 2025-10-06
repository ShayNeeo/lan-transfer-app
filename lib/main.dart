import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'dart:convert';
import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:archive/archive.dart' as arch;
import 'http_server.dart';
import 'package:path/path.dart' as p;

// Global server instance that persists across tab changes
final globalServer = LANFileServer(port: 8000);

void main() {
  runApp(const LANTransferApp());
}

class LANTransferApp extends StatelessWidget {
  const LANTransferApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LAN File Transfer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF667EEA),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF667EEA),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('📁 LAN File Transfer'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.cloud_download), text: 'Client'),
            Tab(icon: Icon(Icons.cloud_upload), text: 'Server'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        physics:
            const NeverScrollableScrollPhysics(), // Prevent accidental swipes
        children: const [
          ClientPage(),
          ServerPage(),
        ],
      ),
    );
  }
}

// Server Page
class ServerPage extends StatefulWidget {
  const ServerPage({super.key});

  @override
  State<ServerPage> createState() => _ServerPageState();
}

class _ServerPageState extends State<ServerPage>
    with AutomaticKeepAliveClientMixin {
  String? _serverIp;
  bool _isStarting = false;
  List<FileInfo> _serverFiles = [];
  bool _isLoadingFiles = false;
  Map<String, List<FileInfo>> _folderContents = {};
  Set<String> _expandedFolders = {};

  // Keep state alive when switching tabs
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _getIpAddress();
    _requestPermissions();
    // Load files if server is already running
    if (globalServer.isRunning) {
      _loadServerFiles();
    }
  }

  @override
  void dispose() {
    // Don't stop server on dispose - let it run when switching tabs
    // Server will only stop when user explicitly clicks "Stop Server"
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    await Permission.manageExternalStorage.request();
    if (Platform.isAndroid) {
      await Permission.photos.request();
      await Permission.videos.request();
      await Permission.audio.request();
    }
  }

  Future<void> _loadServerFiles() async {
    if (!globalServer.isRunning) return;

    setState(() => _isLoadingFiles = true);

    try {
      final files = <FileInfo>[];
      if (await globalServer.uploadDir.exists()) {
        // Get all entities first, then process for better performance
        final entities =
            await globalServer.uploadDir.list(recursive: false).toList();

        for (final entity in entities) {
          final name = p.basename(entity.path);
          if (name.startsWith('.')) continue; // Skip hidden files

          if (entity is Directory) {
            files.add(FileInfo(
              name: name,
              size: '',
              type: 'folder',
              path: name,
            ));
          } else if (entity is File) {
            try {
              final stat = await entity.stat();
              files.add(FileInfo(
                name: name,
                size: _formatFileSize(stat.size),
                type: 'file',
                path: name,
              ));
            } catch (e) {
              // Skip files that can't be accessed
              continue;
            }
          }
        }
      }

      // Sort: folders first, then files (case-insensitive)
      files.sort((a, b) {
        if (a.type != b.type) {
          return a.type == 'folder' ? -1 : 1;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

      if (mounted) {
        setState(() {
          _serverFiles = files;
          _isLoadingFiles = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingFiles = false);
      }
    }
  }

  Future<List<FileInfo>> _loadFolderContents(String folderPath) async {
    try {
      final files = <FileInfo>[];
      final folder = Directory('${globalServer.uploadDir.path}/$folderPath');
      if (!await folder.exists()) return files;

      // List only direct children, not recursive
      await for (final entity in folder.list(recursive: false)) {
        final name = p.basename(entity.path);
        if (entity is Directory) {
          files.add(FileInfo(
            name: name,
            size: '',
            type: 'folder',
            path: '$folderPath/$name',
          ));
        } else if (entity is File) {
          final stat = await entity.stat();
          files.add(FileInfo(
            name: name,
            size: _formatFileSize(stat.size),
            type: 'file',
            path: '$folderPath/$name',
          ));
        }
      }
      // Sort: folders first, then files
      files.sort((a, b) {
        if (a.type != b.type) {
          return a.type == 'folder' ? -1 : 1;
        }
        return a.name.compareTo(b.name);
      });
      return files;
    } catch (e) {
      return [];
    }
  }

  String _formatFileSize(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    double size = bytes.toDouble();
    int unitIndex = 0;

    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }

    return '${size.toStringAsFixed(2)} ${units[unitIndex]}';
  }

  Future<void> _deleteServerFile(String filepath) async {
    final itemPath = '${globalServer.uploadDir.path}/$filepath';
    final isFolder = await Directory(itemPath).exists();
    final itemType = isFolder ? 'folder' : 'file';

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${itemType == 'folder' ? 'Folder' : 'File'}'),
        content: Text(
            'Are you sure you want to delete this $itemType?${isFolder ? ' and all its contents?' : ''}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      if (isFolder) {
        final dir = Directory(itemPath);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      } else {
        final file = File(itemPath);
        if (await file.exists()) {
          await file.delete();
        }
      }

      // Clear all caches and force immediate UI update
      setState(() {
        _folderContents.remove(filepath);
        _expandedFolders.remove(filepath);
        _serverFiles.removeWhere((f) => f.path == filepath);
      });

      // Also reload from disk to ensure consistency
      await _loadServerFiles();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  '${itemType == 'folder' ? 'Folder' : 'File'} deleted successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting $itemType: $e')),
        );
      }
    }
  }

  Future<void> _downloadFolder(String folderPath) async {
    try {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Preparing folder download...')),
        );
      }

      final folder = Directory('${globalServer.uploadDir.path}/$folderPath');
      if (!await folder.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Folder not found')),
          );
        }
        return;
      }

      // Get downloads directory
      final externalDir = await getExternalStorageDirectory();
      final downloadsDir = Directory('${externalDir!.path}/Downloads');
      if (!await downloadsDir.exists()) {
        await downloadsDir.create(recursive: true);
      }

      final folderName = folderPath.split('/').last;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final zipFile = File('${downloadsDir.path}/$folderName-$timestamp.zip');

      // Create archive with better performance
      final archive = arch.Archive();
      final files = <FileSystemEntity>[];

      // Collect all files first for better performance
      await for (final entity in folder.list(recursive: true)) {
        if (entity is File) {
          files.add(entity);
        }
      }

      // Process files in batches to avoid memory issues
      const batchSize = 50;
      for (int i = 0; i < files.length; i += batchSize) {
        final batch = files.skip(i).take(batchSize);
        for (final entity in batch) {
          if (entity is File) {
            final fileBytes = await entity.readAsBytes();
            final relativePath = entity.path.substring(folder.path.length + 1);
            archive.addFile(arch.ArchiveFile(
              relativePath,
              fileBytes.length,
              fileBytes,
            ));
          }
        }
      }

      // Encode to zip with compression
      final zipBytes = arch.ZipEncoder().encode(archive);
      if (zipBytes != null) {
        await zipFile.writeAsBytes(zipBytes);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                  'Folder downloaded: ${files.length} files\nSaved to: ${zipFile.path}'),
              duration: const Duration(seconds: 5),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error downloading folder: $e')),
        );
      }
    }
  }

  Future<void> _openFile(String filename) async {
    final file = File('${globalServer.uploadDir.path}/$filename');
    if (await file.exists()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('File: ${file.path}')),
      );
    }
  }

  Widget _buildFolderTile(FileInfo folder, {int depth = 0}) {
    final isExpanded = _expandedFolders.contains(folder.path);
    final contents = _folderContents[folder.path] ?? [];
    final folderCount = contents.where((f) => f.type == 'folder').length;
    final fileCount = contents.where((f) => f.type == 'file').length;

    return Card(
      margin: EdgeInsets.only(
        left: 16.0 + (depth * 16.0),
        right: 16.0,
        top: 4.0,
        bottom: 4.0,
      ),
      child: Column(
        children: [
          ListTile(
            leading: Icon(
              isExpanded ? Icons.folder_open : Icons.folder,
              color: Colors.amber,
              size: 32,
            ),
            title: Text(
              folder.name,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              contents.isEmpty && !isExpanded
                  ? 'Folder'
                  : '${folderCount > 0 ? '$folderCount folders' : ''}${folderCount > 0 && fileCount > 0 ? ', ' : ''}${fileCount > 0 ? '$fileCount files' : ''}${folderCount == 0 && fileCount == 0 && isExpanded ? 'Empty' : ''}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon:
                      Icon(isExpanded ? Icons.expand_less : Icons.expand_more),
                  onPressed: () async {
                    if (isExpanded) {
                      setState(() {
                        _expandedFolders.remove(folder.path);
                      });
                    } else {
                      final items = await _loadFolderContents(folder.path);
                      setState(() {
                        _folderContents[folder.path] = items;
                        _expandedFolders.add(folder.path);
                      });
                    }
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.download, color: Colors.green),
                  onPressed: () => _downloadFolder(folder.path),
                  tooltip: 'Download folder as ZIP',
                ),
                IconButton(
                  icon: const Icon(Icons.delete, color: Colors.red),
                  onPressed: () => _deleteServerFile(folder.path),
                ),
              ],
            ),
          ),
          if (isExpanded)
            Container(
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.grey.shade900
                  : Colors.grey.shade100,
              padding: const EdgeInsets.only(left: 16, bottom: 8, top: 8),
              child: contents.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text(
                        'Empty folder',
                        style: TextStyle(
                            color: Colors.grey, fontStyle: FontStyle.italic),
                      ),
                    )
                  : Column(
                      children: contents.map((item) {
                        if (item.type == 'folder') {
                          return _buildNestedFolderTile(item, depth: depth + 1);
                        } else {
                          return _buildNestedFileTile(item, depth: depth + 1);
                        }
                      }).toList(),
                    ),
            ),
        ],
      ),
    );
  }

  Widget _buildFileTile(FileInfo file) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        leading: const Icon(Icons.insert_drive_file, size: 32),
        title: Text(file.name),
        subtitle: Text(file.size),
        trailing: IconButton(
          icon: const Icon(Icons.delete, color: Colors.red),
          onPressed: () => _deleteServerFile(file.path),
        ),
        onTap: () => _openFile(file.path),
      ),
    );
  }

  Widget _buildNestedFolderTile(FileInfo folder, {int depth = 0}) {
    final isExpanded = _expandedFolders.contains(folder.path);
    final contents = _folderContents[folder.path] ?? [];

    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.only(left: 16.0 * (depth + 1), right: 16),
          leading: Icon(
            isExpanded ? Icons.folder_open : Icons.folder,
            color: Colors.amber,
            size: 24,
          ),
          title: Text(folder.name,
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          subtitle: Text(
            contents.isEmpty && !isExpanded
                ? 'Folder'
                : '${contents.where((f) => f.type == 'folder').length} folders, ${contents.where((f) => f.type == 'file').length} files',
            style: const TextStyle(fontSize: 12),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(
                  isExpanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                ),
                onPressed: () async {
                  if (isExpanded) {
                    setState(() {
                      _expandedFolders.remove(folder.path);
                    });
                  } else {
                    final items = await _loadFolderContents(folder.path);
                    setState(() {
                      _folderContents[folder.path] = items;
                      _expandedFolders.add(folder.path);
                    });
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.download, color: Colors.green, size: 20),
                onPressed: () => _downloadFolder(folder.path),
                tooltip: 'Download folder as ZIP',
              ),
              IconButton(
                icon: const Icon(Icons.delete, color: Colors.red, size: 20),
                onPressed: () => _deleteServerFile(folder.path),
              ),
            ],
          ),
        ),
        if (isExpanded && contents.isNotEmpty)
          ...contents.map((item) {
            if (item.type == 'folder') {
              return _buildNestedFolderTile(item, depth: depth + 1);
            } else {
              return _buildNestedFileTile(item, depth: depth + 1);
            }
          }).toList(),
        if (isExpanded && contents.isEmpty)
          Padding(
            padding:
                EdgeInsets.only(left: 16.0 * (depth + 2), top: 8, bottom: 8),
            child: const Text(
              'Empty folder',
              style: TextStyle(
                  color: Colors.grey,
                  fontStyle: FontStyle.italic,
                  fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget _buildNestedFileTile(FileInfo file, {int depth = 0}) {
    return ListTile(
      contentPadding: EdgeInsets.only(left: 16.0 * (depth + 1), right: 16),
      leading: const Icon(Icons.insert_drive_file, size: 24),
      title: Text(file.name, style: const TextStyle(fontSize: 14)),
      subtitle: Text(file.size, style: const TextStyle(fontSize: 12)),
      trailing: IconButton(
        icon: const Icon(Icons.delete, color: Colors.red, size: 20),
        onPressed: () => _deleteServerFile(file.path),
      ),
      onTap: () => _openFile(file.path),
    );
  }

  Future<void> _getIpAddress() async {
    try {
      final info = NetworkInfo();
      final wifiIP = await info.getWifiIP();
      setState(() {
        _serverIp = wifiIP;
      });
    } catch (e) {
      setState(() {
        _serverIp = 'Unable to get IP';
      });
    }
  }

  Future<void> _toggleServer() async {
    setState(() => _isStarting = true);

    try {
      if (globalServer.isRunning) {
        await globalServer.stop();
        setState(() => _serverFiles = []);
      } else {
        await globalServer.start();
        await _loadServerFiles();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString()}')),
        );
      }
    }

    setState(() => _isStarting = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveStateMixin
    return Column(
      children: [
        // Server Status Header
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              Icon(
                globalServer.isRunning ? Icons.router : Icons.router_outlined,
                size: 60,
                color: globalServer.isRunning ? Colors.green : Colors.grey,
              ),
              const SizedBox(height: 12),
              Text(
                globalServer.isRunning ? 'Server Running' : 'Server Stopped',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color:
                          globalServer.isRunning ? Colors.green : Colors.grey,
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 16),

              // Server URL Card
              if (globalServer.isRunning && _serverIp != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Column(
                      children: [
                        const Text(
                          'Share this URL:',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          'http://$_serverIp:8000',
                          style: const TextStyle(
                            fontSize: 18,
                            color: Color(0xFF667EEA),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          globalServer.uploadDir.path,
                          style:
                              const TextStyle(fontSize: 10, color: Colors.grey),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),

              const SizedBox(height: 16),

              // Start/Stop Button
              ElevatedButton.icon(
                onPressed: _isStarting ? null : _toggleServer,
                icon: Icon(
                    globalServer.isRunning ? Icons.stop : Icons.play_arrow),
                label: Text(
                  _isStarting
                      ? 'Please wait...'
                      : (globalServer.isRunning
                          ? 'Stop Server'
                          : 'Start Server'),
                ),
                style: ElevatedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  backgroundColor: globalServer.isRunning
                      ? Colors.red
                      : const Color(0xFF667EEA),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),

        const Divider(),

        // Files Section
        Expanded(
          child: globalServer.isRunning
              ? Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16.0, vertical: 8.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Hosted Files (${_serverFiles.length})',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.refresh),
                            onPressed: _loadServerFiles,
                            tooltip: 'Refresh',
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: _isLoadingFiles
                          ? const Center(child: CircularProgressIndicator())
                          : _serverFiles.isEmpty
                              ? Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.folder_open,
                                        size: 64,
                                        color: Colors.grey.shade400,
                                      ),
                                      const SizedBox(height: 16),
                                      Text(
                                        'No files yet',
                                        style: TextStyle(
                                          fontSize: 16,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        'Upload files via the web interface',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey.shade500,
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              : ListView.builder(
                                  itemCount: _serverFiles.length,
                                  itemBuilder: (context, index) {
                                    final file = _serverFiles[index];
                                    if (file.type == 'folder') {
                                      return _buildFolderTile(file);
                                    } else {
                                      return _buildFileTile(file);
                                    }
                                  },
                                ),
                    ),
                  ],
                )
              : Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.info_outline,
                          color: Colors.blue.shade300,
                          size: 60,
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Start the server to allow other devices on your network to upload and download files.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

// Client Page (original functionality)
class ClientPage extends StatefulWidget {
  const ClientPage({super.key});

  @override
  State<ClientPage> createState() => _ClientPageState();
}

class _ClientPageState extends State<ClientPage>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _serverController = TextEditingController();
  List<FileInfo> _files = [];
  bool _isLoading = false;
  String? _statusMessage;
  bool _isError = false;
  double _uploadProgress = 0.0;
  bool _isUploading = false;

  // Keep state alive when switching tabs
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    await Permission.storage.request();
    if (Platform.isAndroid && await _isAndroid13OrHigher()) {
      await Permission.photos.request();
      await Permission.videos.request();
    }
  }

  Future<bool> _isAndroid13OrHigher() async {
    return Platform.isAndroid;
  }

  String get _serverUrl {
    final url = _serverController.text.trim();
    if (url.isEmpty) return '';
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return 'http://$url';
    }
    return url;
  }

  Future<void> _loadFiles() async {
    if (_serverUrl.isEmpty) {
      _showStatus('Please enter server address', isError: true);
      return;
    }

    setState(() {
      _isLoading = true;
      _statusMessage = null;
    });

    try {
      final response = await http.get(Uri.parse('$_serverUrl/files')).timeout(
            const Duration(seconds: 10),
          );

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        final List<dynamic> data =
            responseData is Map ? responseData['items'] ?? [] : responseData;
        setState(() {
          _files = data.map((f) => FileInfo.fromJson(f)).toList();
          _isLoading = false;
        });
      } else {
        _showStatus('Failed to load files', isError: true);
        setState(() => _isLoading = false);
      }
    } catch (e) {
      _showStatus('Connection error: ${e.toString()}', isError: true);
      setState(() => _isLoading = false);
    }
  }

  Future<void> _uploadFiles() async {
    if (_serverUrl.isEmpty) {
      _showStatus('Please enter server address', isError: true);
      return;
    }

    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
      );

      if (result == null) return;

      setState(() {
        _isUploading = true;
        _uploadProgress = 0.0;
      });

      var request = http.MultipartRequest(
        'POST',
        Uri.parse('$_serverUrl/upload'),
      );

      int totalFiles = result.files.length;
      for (var file in result.files) {
        if (file.path != null) {
          request.files.add(
            await http.MultipartFile.fromPath('files', file.path!),
          );
        }
      }

      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);

      setState(() {
        _isUploading = false;
        _uploadProgress = 0.0;
      });

      if (response.statusCode == 200) {
        _showStatus('$totalFiles file(s) uploaded successfully!');
        _loadFiles();
      } else {
        _showStatus('Upload failed', isError: true);
      }
    } catch (e) {
      setState(() {
        _isUploading = false;
        _uploadProgress = 0.0;
      });
      _showStatus('Upload error: ${e.toString()}', isError: true);
    }
  }

  Future<void> _uploadFolder() async {
    if (_serverUrl.isEmpty) {
      _showStatus('Please enter server address', isError: true);
      return;
    }

    try {
      String? directoryPath = await FilePicker.platform.getDirectoryPath();

      if (directoryPath == null) return;

      final directory = Directory(directoryPath);
      if (!await directory.exists()) {
        _showStatus('Directory not found', isError: true);
        return;
      }

      setState(() {
        _isUploading = true;
        _uploadProgress = 0.0;
      });

      // Get the folder name to preserve it in upload
      final folderName = directory.path.split('/').last;

      // Collect all files from the directory recursively
      final files = <File>[];
      await for (final entity in directory.list(recursive: true)) {
        if (entity is File) {
          files.add(entity);
        }
      }

      if (files.isEmpty) {
        setState(() {
          _isUploading = false;
          _uploadProgress = 0.0;
        });
        _showStatus('No files found in folder', isError: true);
        return;
      }

      var request = http.MultipartRequest(
        'POST',
        Uri.parse('$_serverUrl/upload'),
      );

      for (var file in files) {
        // Preserve folder structure with the root folder name
        String relativePath = file.path.substring(directoryPath.length + 1);
        String fullPath = '$folderName/$relativePath';
        request.files.add(
          await http.MultipartFile.fromPath('files', file.path,
              filename: fullPath),
        );
      }

      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);

      setState(() {
        _isUploading = false;
        _uploadProgress = 0.0;
      });

      if (response.statusCode == 200) {
        _showStatus(
            '${files.length} file(s) from folder uploaded successfully!');
        _loadFiles();
      } else {
        _showStatus('Upload failed', isError: true);
      }
    } catch (e) {
      setState(() {
        _isUploading = false;
        _uploadProgress = 0.0;
      });
      _showStatus('Upload error: ${e.toString()}', isError: true);
    }
  }

  Future<void> _downloadFile(String filename) async {
    if (_serverUrl.isEmpty) return;

    try {
      _showStatus('Downloading $filename...');

      final response = await http.get(
        Uri.parse('$_serverUrl/download/${Uri.encodeComponent(filename)}'),
      );

      if (response.statusCode == 200) {
        final directory = await getExternalStorageDirectory();
        final downloadsDir = Directory('${directory!.path}/Downloads');
        if (!await downloadsDir.exists()) {
          await downloadsDir.create(recursive: true);
        }

        // Handle nested file paths by creating directories
        final file = File('${downloadsDir.path}/$filename');
        final parentDir = file.parent;
        if (!await parentDir.exists()) {
          await parentDir.create(recursive: true);
        }

        await file.writeAsBytes(response.bodyBytes);
        _showStatus('Downloaded to: ${file.path}');
      } else {
        _showStatus('Download failed', isError: true);
      }
    } catch (e) {
      _showStatus('Download error: ${e.toString()}', isError: true);
    }
  }

  Future<void> _deleteFile(String filename) async {
    if (_serverUrl.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Item'),
        content: Text('Are you sure you want to delete $filename?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final response = await http.get(
        Uri.parse('$_serverUrl/delete/${Uri.encodeComponent(filename)}'),
      );

      if (response.statusCode == 200) {
        _showStatus('Item deleted successfully');
        _loadFiles();
      } else {
        _showStatus('Delete failed', isError: true);
      }
    } catch (e) {
      _showStatus('Delete error: ${e.toString()}', isError: true);
    }
  }

  void _showStatus(String message, {bool isError = false}) {
    setState(() {
      _statusMessage = message;
      _isError = isError;
    });

    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _statusMessage = null);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveStateMixin
    return Scaffold(
      body: Column(
        children: [
          // Server address input
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _serverController,
                    decoration: const InputDecoration(
                      labelText: 'Server Address',
                      hintText: '192.168.1.100:8000',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.dns),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _loadFiles,
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh',
                ),
              ],
            ),
          ),

          // Status message
          if (_statusMessage != null)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _isError ? Colors.red.shade100 : Colors.green.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    _isError ? Icons.error : Icons.check_circle,
                    color:
                        _isError ? Colors.red.shade700 : Colors.green.shade700,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _statusMessage!,
                      style: TextStyle(
                        color: _isError
                            ? Colors.red.shade700
                            : Colors.green.shade700,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // Upload progress
          if (_isUploading)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  const Text('Uploading...'),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: _uploadProgress),
                ],
              ),
            ),

          const SizedBox(height: 16),

          // Files list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _files.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.folder_open,
                              size: 64,
                              color: Colors.grey.shade400,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No files uploaded yet',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        itemCount: _files.length,
                        itemBuilder: (context, index) {
                          final file = _files[index];
                          return Card(
                            margin: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 4,
                            ),
                            child: ListTile(
                              leading: const Icon(Icons.insert_drive_file),
                              title: Text(file.name),
                              subtitle: Text(file.size),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.download),
                                    color: Colors.green,
                                    onPressed: () => _downloadFile(file.name),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete),
                                    color: Colors.red,
                                    onPressed: () => _deleteFile(file.name),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            onPressed: _isUploading ? null : _uploadFiles,
            heroTag: 'upload_files',
            icon: const Icon(Icons.upload_file),
            label: const Text('Upload Files'),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            onPressed: _isUploading ? null : _uploadFolder,
            heroTag: 'upload_folder',
            icon: const Icon(Icons.folder_open),
            label: const Text('Upload Folder'),
            backgroundColor: Colors.deepPurple,
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _serverController.dispose();
    super.dispose();
  }
}

class FileInfo {
  final String name;
  final String size;
  final String type;
  final String path;

  FileInfo({
    required this.name,
    required this.size,
    this.type = 'file',
    this.path = '',
  });

  factory FileInfo.fromJson(Map<String, dynamic> json) {
    return FileInfo(
      name: json['name'] as String,
      size: json['size'] as String? ?? '',
      type: json['type'] as String? ?? 'file',
      path: json['path'] as String? ?? '',
    );
  }
}
