import 'dart:io';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart' as arch;
import 'package:path/path.dart' as p;

class LANFileServer {
  HttpServer? _server;
  final int port;
  late Directory uploadDir;
  bool _isRunning = false;

  LANFileServer({this.port = 8000});

  bool get isRunning => _isRunning;

  Future<void> start() async {
    if (_isRunning) return;

    // Setup upload directory in external storage (like normal APKs)
    final externalDir = await getExternalStorageDirectory();
    if (externalDir != null) {
      // Use /storage/emulated/0/Android/data/com.shayneeo.localshare/files/uploads
      uploadDir = Directory('${externalDir.path}/uploads');
    } else {
      // Fallback to app directory if external storage not available
      final appDir = await getApplicationDocumentsDirectory();
      uploadDir = Directory('${appDir.path}/uploads');
    }
    if (!await uploadDir.exists()) {
      await uploadDir.create(recursive: true);
    }

    final router = Router();

    // Serve main page
    router.get('/', _handleMainPage);
    router.get('/index.html', _handleMainPage);

    // API endpoints
    router.get('/files', _handleFileList);
    // Allow nested paths (including slashes) in parameters using regex capture
    router.get('/download/<filename|.*>', _handleDownload);
    router.get('/download-folder/<folderpath|.*>', _handleFolderDownload);
    router.get('/delete/<filename|.*>', _handleDelete);
    router.post('/upload', _handleUpload);

    final handler = const shelf.Pipeline()
        .addMiddleware(shelf.logRequests())
        .addHandler(router.call);

    _server = await io.serve(handler, InternetAddress.anyIPv4, port);
    _isRunning = true;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _isRunning = false;
  }

  shelf.Response _handleMainPage(shelf.Request request) {
    final html = _generateHTML();
    return shelf.Response.ok(
      html,
      headers: {'Content-Type': 'text/html'},
    );
  }

  Future<shelf.Response> _handleFileList(shelf.Request request) async {
    try {
      final files = <Map<String, dynamic>>[];

      // Get path parameter for subfolder navigation (within uploadDir only)
      final path = request.url.queryParameters['path'] ?? '';
      final targetPath = path.isEmpty
          ? uploadDir.path
          : p.normalize(p.join(uploadDir.path, path));
      final rootPath = uploadDir.path;
      final isAllowed =
          targetPath == rootPath || p.isWithin(rootPath, targetPath);
      if (!isAllowed) {
        return shelf.Response.forbidden(
          json.encode(
              {'items': [], 'currentPath': path, 'error': 'Access denied'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
      final targetDir = Directory(targetPath);

      if (!await targetDir.exists()) {
        return shelf.Response.notFound(
          json.encode({
            'items': [],
            'currentPath': path,
            'error': 'Directory not found'
          }),
          headers: {'Content-Type': 'application/json'},
        );
      }

      // List only direct children, not recursive
      await for (final entity in targetDir.list(recursive: false)) {
        final name = p.basename(entity.path);
        if (name.isEmpty) {
          // Skip entities with no resolvable name
          continue;
        }
        if (entity is Directory) {
          files.add({
            'name': name,
            'type': 'folder',
            'size': '',
            'path': path.isEmpty ? name : '$path/$name',
          });
        } else if (entity is File) {
          final stat = await entity.stat();
          files.add({
            'name': name,
            'type': 'file',
            'size': _formatFileSize(stat.size),
            'path': path.isEmpty ? name : '$path/$name',
          });
        }
      }

      // Sort: folders first, then files, alphabetically
      files.sort((a, b) {
        if (a['type'] != b['type']) {
          return a['type'] == 'folder' ? -1 : 1;
        }
        return a['name']!.compareTo(b['name']!);
      });

      return shelf.Response.ok(
        json.encode({'items': files, 'currentPath': path}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return shelf.Response.internalServerError(
        body: json.encode({
          'items': [],
          'currentPath': request.url.queryParameters['path'] ?? '',
          'error': 'Error listing files: $e'
        }),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  Future<shelf.Response> _handleDownload(
      shelf.Request request, String filename) async {
    try {
      // Construct a safe absolute path within the upload directory
      final safePath = p.normalize(p.join(uploadDir.path, filename));
      if (!p.isWithin(uploadDir.path, safePath)) {
        return shelf.Response.forbidden('Access denied');
      }

      final file = File(safePath);
      if (!await file.exists()) {
        return shelf.Response.notFound('File not found');
      }

      final bytes = await file.readAsBytes();
      // Extract just the filename for Content-Disposition
      final displayName = p.basename(filename);
      final mimeType =
          lookupMimeType(displayName) ?? 'application/octet-stream';

      return shelf.Response.ok(
        bytes,
        headers: {
          'Content-Type': mimeType,
          'Content-Disposition': 'attachment; filename="$displayName"',
        },
      );
    } catch (e) {
      return shelf.Response.internalServerError(body: 'Error serving file: $e');
    }
  }

  Future<shelf.Response> _handleFolderDownload(
      shelf.Request request, String folderpath) async {
    try {
      // Construct a safe absolute path within the upload directory
      final safeFolderPath = p.normalize(p.join(uploadDir.path, folderpath));
      if (!p.isWithin(uploadDir.path, safeFolderPath)) {
        return shelf.Response.forbidden('Access denied');
      }

      final folder = Directory(safeFolderPath);
      if (!await folder.exists()) {
        return shelf.Response.notFound('Folder not found');
      }

      final archive = arch.Archive();

      // Collect all files
      final files = <File>[];
      await for (final entity in folder.list(recursive: true)) {
        if (entity is File) {
          files.add(entity);
        }
      }

      // Add files to archive with better performance
      const batchSize = 50;
      for (int i = 0; i < files.length; i += batchSize) {
        final batch = files.skip(i).take(batchSize);
        for (final file in batch) {
          try {
            final fileBytes = await file.readAsBytes();
            final relativePath = file.path.substring(folder.path.length + 1);
            archive.addFile(arch.ArchiveFile(
              relativePath,
              fileBytes.length,
              fileBytes,
            ));
          } catch (e) {
            // Skip files that can't be read
            developer.log('Skipping file ${file.path}: $e');
            continue;
          }
        }
      }

      // Encode to zip
      final zipBytes = arch.ZipEncoder().encode(archive);
      if (zipBytes == null) {
        return shelf.Response.internalServerError(
            body: 'Failed to create zip archive');
      }

      final folderName = folderpath.split('/').last;
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      return shelf.Response.ok(
        zipBytes,
        headers: {
          'Content-Type': 'application/zip',
          'Content-Disposition':
              'attachment; filename="$folderName-$timestamp.zip"',
        },
      );
    } catch (e) {
      return shelf.Response.internalServerError(
          body: 'Error creating folder archive: $e');
    }
  }

  Future<shelf.Response> _handleDelete(
      shelf.Request request, String filename) async {
    try {
      final safePath = p.normalize(p.join(uploadDir.path, filename));

      // Security check
      if (!p.isWithin(uploadDir.path, safePath)) {
        return shelf.Response.forbidden('Access denied');
      }

      final file = File(safePath);
      final dir = Directory(safePath);

      if (await file.exists()) {
        await file.delete();
        return shelf.Response.ok('File deleted successfully');
      } else if (await dir.exists()) {
        await dir.delete(recursive: true);
        return shelf.Response.ok('Folder deleted successfully');
      } else {
        return shelf.Response.notFound('File or folder not found');
      }
    } catch (e) {
      return shelf.Response.internalServerError(body: 'Error deleting: $e');
    }
  }

  Future<shelf.Response> _handleUpload(shelf.Request request) async {
    try {
      final contentType = request.headers['content-type'];
      if (contentType == null ||
          !contentType.startsWith('multipart/form-data')) {
        return shelf.Response.badRequest(body: 'Invalid content type');
      }

      // Extract boundary more carefully
      String boundary;
      if (contentType.contains('boundary=')) {
        boundary = contentType.split('boundary=')[1].trim();
        // Remove quotes if present
        if (boundary.startsWith('"') && boundary.endsWith('"')) {
          boundary = boundary.substring(1, boundary.length - 1);
        }
      } else {
        return shelf.Response.badRequest(
            body: 'No boundary found in content-type');
      }

      final boundaryBytes = utf8.encode('--$boundary');
      final bytes = await request.read().expand((chunk) => chunk).toList();

      developer.log('Received ${bytes.length} bytes for upload');
      developer.log('Boundary: --$boundary (${boundaryBytes.length} bytes)');

      int uploadedCount = 0;
      int i = 0;

      // Skip any leading data before first boundary
      int firstBoundary = _findBoundary(bytes, boundaryBytes, 0);
      if (firstBoundary != -1) {
        i = firstBoundary;
      }

      while (i < bytes.length) {
        // Find boundary
        int boundaryIndex = _findBoundary(bytes, boundaryBytes, i);
        if (boundaryIndex == -1) break;

        i = boundaryIndex + boundaryBytes.length;
        if (i >= bytes.length) break;

        // Check for closing boundary (--boundary--)
        if (i + 1 < bytes.length && bytes[i] == 45 && bytes[i + 1] == 45) {
          break; // This is the final boundary
        }

        // Skip \r\n after boundary
        if (i + 1 < bytes.length && bytes[i] == 13 && bytes[i + 1] == 10) {
          i += 2;
        }

        // Find headers end (\r\n\r\n)
        int headersEnd = _findSequence(bytes, [13, 10, 13, 10], i);
        if (headersEnd == -1) break;

        // Parse headers to get filename
        final headerBytes = bytes.sublist(i, headersEnd);
        final headers = utf8.decode(headerBytes);
        developer.log('Headers: $headers');

        final filenameMatch = RegExp(r'filename="([^"]+)"').firstMatch(headers);

        if (filenameMatch == null) {
          developer.log('No filename found in headers');
          i = headersEnd + 4;
          continue;
        }

        final filename = filenameMatch.group(1);
        if (filename == null || filename.isEmpty) {
          developer.log('Empty filename');
          i = headersEnd + 4;
          continue;
        }

        developer.log('Processing file: $filename');

        // Find next boundary
        int dataStart = headersEnd + 4;
        int nextBoundaryIndex = _findBoundary(bytes, boundaryBytes, dataStart);
        if (nextBoundaryIndex == -1) {
          developer.log('No next boundary found');
          break;
        }

        // Extract file data (remove trailing \r\n before boundary)
        int dataEnd = nextBoundaryIndex;
        if (dataEnd >= 2 &&
            bytes[dataEnd - 2] == 13 &&
            bytes[dataEnd - 1] == 10) {
          dataEnd -= 2;
        }

        final fileData = bytes.sublist(dataStart, dataEnd);
        developer.log('File data size: ${fileData.length} bytes');

        // Save file with binary data, creating directories if needed
        // Build a safe destination path within uploadDir
        final destPath = p.normalize(p.join(uploadDir.path, filename));
        if (!p.isWithin(uploadDir.path, destPath)) {
          developer.log('Skipping file outside upload directory: $filename');
          i = nextBoundaryIndex;
          continue;
        }

        final file = File(destPath);
        // Create parent directories if they don't exist
        final parentDir = file.parent;
        if (!await parentDir.exists()) {
          await parentDir.create(recursive: true);
          developer.log('Created directory: ${parentDir.path}');
        }
        await file.writeAsBytes(fileData);
        developer.log('Saved file: ${file.path}');
        uploadedCount++;

        i = nextBoundaryIndex;
      }

      developer.log('Total files uploaded: $uploadedCount');

      if (uploadedCount > 0) {
        return shelf.Response.ok(
            '$uploadedCount file(s) uploaded successfully');
      } else {
        return shelf.Response.badRequest(body: 'No files uploaded');
      }
    } catch (e, stackTrace) {
      developer.log('Upload error: $e');
      developer.log('Stack trace: $stackTrace');
      return shelf.Response.internalServerError(
          body: 'Error uploading files: $e');
    }
  }

  int _findBoundary(List<int> bytes, List<int> boundary, int start) {
    for (int i = start; i <= bytes.length - boundary.length; i++) {
      bool found = true;
      for (int j = 0; j < boundary.length; j++) {
        if (bytes[i + j] != boundary[j]) {
          found = false;
          break;
        }
      }
      if (found) return i;
    }
    return -1;
  }

  int _findSequence(List<int> bytes, List<int> sequence, int start) {
    for (int i = start; i <= bytes.length - sequence.length; i++) {
      bool found = true;
      for (int j = 0; j < sequence.length; j++) {
        if (bytes[i + j] != sequence[j]) {
          found = false;
          break;
        }
      }
      if (found) return i;
    }
    return -1;
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

  String _generateHTML() {
    return '''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>LAN File Transfer</title>
  <style>
    :root {
      color-scheme: light;
    }
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: 'Orbitron', 'Press Start 2P', system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif;
      background: #ffffff;
      min-height: 100vh;
      padding: 24px;
      color: #000000;
    }
    .container { max-width: 940px; margin: 0 auto; }
    .header { text-align: center; margin-bottom: 28px; text-transform: uppercase; letter-spacing: 2px; }
    .header h1 { font-size: 2.4em; margin-bottom: 10px; }
    .header p { font-size: 0.9em; color: #111111; }
    .card {
      background: #ffffff;
      border-radius: 18px;
      padding: 32px 28px;
      border: 2px solid #000000;
      box-shadow: 8px 8px 0 #000000;
      margin-bottom: 24px;
    }
    .upload-section h2, .files-section h2 {
      text-transform: uppercase;
      letter-spacing: 3px;
      margin-bottom: 20px;
    }
    .upload-section label {
      display: block;
      font-weight: 700;
      letter-spacing: 1.5px;
      font-size: 0.75em;
      margin-bottom: 6px;
      text-transform: uppercase;
    }
    .upload-section input[type="file"] {
      width: 100%;
      padding: 12px;
      border: 2px solid #000000;
      border-radius: 12px;
      background: #ffffff;
      color: #000000;
    }
    .upload-section input[type="file"]::file-selector-button {
      border: 2px solid #000000;
      border-radius: 8px;
      padding: 8px 12px;
      margin-right: 12px;
      background: #ffffff;
      color: #000000;
      font-weight: 700;
      cursor: pointer;
      text-transform: uppercase;
      letter-spacing: 1px;
    }
    .upload-btn {
      background: #000000;
      color: #ffffff;
      border: 2px solid #000000;
      padding: 14px 36px;
      font-size: 0.95em;
      border-radius: 999px;
      cursor: pointer;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 2px;
      transition: transform 120ms ease, background 120ms ease, color 120ms ease;
    }
    .upload-btn:hover {
      transform: translateY(-3px);
      background: #ffffff;
      color: #000000;
    }
    #status {
      margin-top: 18px;
      min-height: 26px;
      text-align: center;
      letter-spacing: 1px;
    }
    ul { list-style: none; }
    .file-item {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 16px;
      border-bottom: 1px solid #000000;
    }
    .btn {
      padding: 10px 18px;
      border: 2px solid #000000;
      border-radius: 10px;
      cursor: pointer;
      margin-left: 10px;
      font-weight: 700;
      background: #ffffff;
      color: #000000;
      text-transform: uppercase;
      letter-spacing: 1px;
      transition: transform 120ms ease, background 120ms ease, color 120ms ease;
    }
    .btn:hover { transform: translateY(-2px); }
    .download-btn { background: #ffffff; color: #000000; }
    .delete-btn { background: #000000; color: #ffffff; }
    .folder-item {
      background: #ffffff;
      border: 2px solid #000000;
      border-radius: 16px;
      margin-bottom: 12px;
      box-shadow: 6px 6px 0 #000000;
    }
    .folder-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 14px 18px;
      cursor: pointer;
    }
    .folder-header:hover { background: #f5f5f5; }
    .folder-content {
      padding-left: 20px;
      padding-right: 18px;
      padding-bottom: 14px;
      background: #ffffff;
      display: none;
      border-top: 2px solid #000000;
      margin-left: 0;
      border-left: none;
    }
    .folder-content.expanded { display: block; }
    .file-item-nested {
      padding: 10px 14px;
      border-bottom: 1px solid #000000;
      display: flex;
      justify-content: space-between;
      align-items: center;
    }
    .file-item-nested:last-child { border-bottom: none; }
    .expand-icon { transition: transform 0.3s; display: inline-block; margin-right: 8px; }
    .expand-icon.expanded { transform: rotate(90deg); }
    .nested-folder {
      margin: 8px 0;
      border-left: none;
      background: #ffffff;
      border: 2px solid #000000;
      border-radius: 14px;
      box-shadow: 4px 4px 0 #000000;
    }
    .nested-folder .folder-header { padding: 12px 16px; }
    .nested-folder .folder-content { padding-left: 16px; padding-right: 16px; }
    .empty-state {
      text-align: center;
      padding: 20px;
      color: #555555;
      font-style: italic;
    }
    @media (max-width: 640px) {
      body { padding: 16px; }
      .card { padding: 24px 18px; box-shadow: 6px 6px 0 #000000; }
      .btn { width: 100%; margin-left: 0; margin-top: 8px; }
    }
  </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>📁 LAN File Transfer</h1>
            <p>Hosted on Android Device</p>
        </div>
        <div class="card upload-section">
            <h2>📤 Upload Files</h2>
            <div style="display: flex; gap: 10px; margin-bottom: 15px; flex-wrap: wrap;">
                <div style="flex: 1; min-width: 200px;">
                    <label for="fileInput" style="display: block; margin-bottom: 5px; font-weight: 600;">📄 Select Files</label>
          <input type="file" id="fileInput" multiple>
                </div>
                <div style="flex: 1; min-width: 200px;">
                    <label for="folderInput" style="display: block; margin-bottom: 5px; font-weight: 600;">📁 Select Folder(s)</label>
          <input type="file" id="folderInput" webkitdirectory directory multiple>
                </div>
            </div>
            <button class="upload-btn" onclick="uploadFiles()">Upload</button>
            <div id="status"></div>
        </div>
        <div class="card files-section">
            <h2>📥 Available Files</h2>
            <ul id="fileList"></ul>
        </div>
    </div>
    <script>
        async function uploadFiles() {
            const fileInput = document.getElementById('fileInput');
            const folderInput = document.getElementById('folderInput');
            const files = fileInput.files.length > 0 ? fileInput.files : folderInput.files;
            if (!files.length) {
                document.getElementById('status').textContent = 'Please select files or folder';
                return;
            }
            const formData = new FormData();
            for (let file of files) {
                // Preserve folder structure using webkitRelativePath for folders
                const filename = file.webkitRelativePath || file.name;
                formData.append('files', file, filename);
            }
            try {
                document.getElementById('status').textContent = 'Uploading...';
                const response = await fetch('/upload', { method: 'POST', body: formData });
                if (response.ok) {
                    document.getElementById('status').textContent = 'Upload successful!';
                    fileInput.value = '';
                    folderInput.value = '';
                    folderContents = {};
                    expandedFolders.clear();
                    await loadFiles();
                } else {
                    document.getElementById('status').textContent = 'Upload failed';
                }
            } catch (e) {
                document.getElementById('status').textContent = 'Upload failed: ' + e.message;
            }
        }
        
        let folderContents = {};
        let expandedFolders = new Set();
        
        async function loadFolderContents(path) {
            if (folderContents[path]) return folderContents[path];
            try {
                const response = await fetch('/files?path=' + encodeURIComponent(path));
                const data = await response.json();
                folderContents[path] = data.items;
                return data.items;
            } catch (e) {
                return [];
            }
        }
        
        async function toggleFolder(path, element) {
            const contentDiv = element.nextElementSibling;
            const icon = element.querySelector('.expand-icon');
            
            if (expandedFolders.has(path)) {
                expandedFolders.delete(path);
                contentDiv.classList.remove('expanded');
                icon.classList.remove('expanded');
            } else {
                expandedFolders.add(path);
                const items = await loadFolderContents(path);
                contentDiv.innerHTML = await renderFolderItems(items, path);
                contentDiv.classList.add('expanded');
                icon.classList.add('expanded');
            }
        }
        
        async function renderFolderItems(items, basePath) {
            if (!items || items.length === 0) {
                return '<div style="padding: 12px; color: #999; font-style: italic;">Empty folder</div>';
            }
            
            let html = '';
            for (const item of items) {
                const escapedPath = item.path.replace(/'/g, "\\\\'");
                const escapedName = item.name.replace(/</g, '&lt;').replace(/>/g, '&gt;');
                
                if (item.type === 'folder') {
                    html += '<div class="nested-folder"><div class="folder-header" onclick="toggleFolder(\\'' + escapedPath + '\\', this)"><div style="display: flex; align-items: center;"><span class="expand-icon">▶</span><strong style="font-size: 1.1em;">📁</strong><span style="margin-left: 8px; font-weight: 600;">' + escapedName + '</span></div><div style="display: flex; gap: 6px;"><a href="/download-folder/' + encodeURIComponent(item.path) + '" class="btn download-btn" download style="padding: 6px 12px; font-size: 0.9em;">Download ZIP</a><button class="btn delete-btn" onclick="event.stopPropagation(); deleteItem(\\'' + escapedPath + '\\', true)" style="padding: 6px 12px; font-size: 0.9em;">Delete</button></div></div><div class="folder-content"></div></div>';
                } else {
                    html += '<div class="file-item-nested"><div style="flex: 1; display: flex; align-items: center;"><strong style="font-size: 1.1em;">📄</strong><span style="margin-left: 8px;">' + escapedName + '</span><span style="margin-left: 10px; color: #888; font-size: 0.9em;">' + item.size + '</span></div><div style="display: flex; gap: 6px;"><a href="/download/' + encodeURIComponent(item.path) + '" class="btn download-btn" download style="padding: 6px 12px; font-size: 0.9em;">Download</a><button class="btn delete-btn" onclick="deleteItem(\\'' + escapedPath + '\\', false)" style="padding: 6px 12px; font-size: 0.9em;">Delete</button></div></div>';
                }
            }
            return html;
        }
        
    async function loadFiles() {
      let data;
      try {
        const response = await fetch('/files');
        data = await response.json();
      } catch (e) {
        console.error('Failed to load files', e);
        const list = document.getElementById('fileList');
        list.innerHTML = '<div style="text-align: center; padding: 20px; color: #999;">Error loading files</div>';
        return;
      }
      const list = document.getElementById('fileList');
            
      let html = '';
            
      for (const item of data.items) {
        const escapedPath = item.path.replace(/'/g, "\\'");
        const escapedName = item.name.replace(/</g, '&lt;').replace(/>/g, '&gt;');
                
        if (item.type === 'folder') {
          const isExpanded = expandedFolders.has(item.path);
          html += '<li class="folder-item"><div class="folder-header" onclick="toggleFolder(\\'' + escapedPath + '\\', this)"><div style="display: flex; align-items: center;"><span class="expand-icon' + (isExpanded ? ' expanded' : '') + '">▶</span><strong style="font-size: 1.2em;">📁</strong><span style="margin-left: 10px; font-weight: 600;">' + escapedName + '</span></div><div style="display: flex; gap: 8px;"><a href="/download-folder/' + encodeURIComponent(item.path) + '" class="btn download-btn" download onclick="event.stopPropagation()">Download ZIP</a><button class="btn delete-btn" onclick="event.stopPropagation(); deleteItem(\\'' + escapedPath + '\\', true)">Delete</button></div></div><div class="folder-content' + (isExpanded ? ' expanded' : '') + '"></div></li>';
        } else {
          html += '<li class="file-item" style="display: flex; justify-content: space-between; align-items: center; padding: 12px;"><div style="flex: 1; display: flex; align-items: center;"><strong style="font-size: 1.2em;">📄</strong><span style="margin-left: 10px; font-weight: 600;">' + escapedName + '</span><span style="margin-left: 10px; color: #888;">' + item.size + '</span></div><div style="display: flex; gap: 8px;"><a href="/download/' + encodeURIComponent(item.path) + '" class="btn download-btn" download>Download</a><button class="btn delete-btn" onclick="deleteItem(\\'' + escapedPath + '\\', false)">Delete</button></div></li>';
        }
      }
            
      list.innerHTML = html || '<div style="text-align: center; padding: 20px; color: #999;">No files yet</div>';
            
      // Re-expand folders that were expanded
      for (const path of expandedFolders) {
        const items = await loadFolderContents(path);
        const folderElements = document.querySelectorAll('.folder-header');
        for (const elem of folderElements) {
          if (elem.onclick && elem.onclick.toString().includes(path)) {
            const contentDiv = elem.nextElementSibling;
            if (contentDiv) {
              contentDiv.innerHTML = await renderFolderItems(items, path);
              contentDiv.classList.add('expanded');
              elem.querySelector('.expand-icon')?.classList.add('expanded');
            }
          }
        }
      }
    }
        
        async function deleteItem(path, isFolder) {
            const itemType = isFolder ? 'folder' : 'file';
            if (!confirm('Delete this ' + itemType + '?' + (isFolder ? ' This will delete all contents.' : ''))) return;
            const response = await fetch('/delete/' + encodeURIComponent(path));
            if (response.ok) {
                // Clear cached folder contents
                delete folderContents[path];
                expandedFolders.delete(path);
                // Refresh view
                await loadFiles();
                document.getElementById('status').textContent = itemType.charAt(0).toUpperCase() + itemType.slice(1) + ' deleted successfully';
                setTimeout(function() { document.getElementById('status').textContent = ''; }, 3000);
            } else {
                document.getElementById('status').textContent = 'Failed to delete ' + itemType;
            }
        }
        
        loadFiles();
        setInterval(loadFiles, 5000);
    </script>
</body>
</html>''';
  }
}
