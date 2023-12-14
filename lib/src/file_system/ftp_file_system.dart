// ignore_for_file: constant_identifier_names

import 'dart:async';
import 'dart:convert';

import 'package:pure_ftp/pure_ftp.dart';
import 'package:pure_ftp/src/file_system/entries/ftp_directory.dart';
import 'package:pure_ftp/src/file_system/entries/ftp_file.dart';
import 'package:pure_ftp/src/file_system/entries/ftp_link.dart';
import 'package:pure_ftp/src/file_system/ftp_entry.dart';
import 'package:pure_ftp/src/file_system/ftp_entry_info.dart';
import 'package:pure_ftp/src/file_system/ftp_transfer.dart';
import 'package:pure_ftp/src/ftp/exceptions/ftp_exception.dart';
import 'package:pure_ftp/src/ftp/extensions/ftp_command_extension.dart';
import 'package:pure_ftp/src/ftp/extensions/string_find_extension.dart';
import 'package:pure_ftp/src/ftp/ftp_commands.dart';
import 'package:pure_ftp/src/ftp/utils/data_parser_utils.dart';
import 'package:pure_ftp/src/ftp_client.dart';
import 'package:pure_ftp/utils/list_utils.dart';

typedef DirInfoCache
    = MapEntry<String, Iterable<MapEntry<FtpEntry, FtpEntryInfo>>>;

class FtpFileSystem {
  var _rootPath = '/';
  final FtpClient _client;
  late final FtpTransfer _transfer;
  late FtpDirectory _currentDirectory;
  ListType listType = ListType.LIST;
  final List<DirInfoCache> _dirInfoCache = [];

  FtpFileSystem({
    required FtpClient client,
  }) : _client = client {
    _currentDirectory = rootDirectory;
    _transfer = FtpTransfer(socket: _client.socket);
  }

  Future<void> init() async {
    final response = await FtpCommand.PWD.writeAndRead(_client.socket);
    if (response.isSuccessful) {
      final path = response.message.find('"', '"');
      _currentDirectory = FtpDirectory(
        path: path,
        client: _client,
      );
      _rootPath = path;
    }
  }

  bool isRoot(FtpDirectory directory) => directory.path == _rootPath;

  FtpDirectory get currentDirectory => _currentDirectory;

  FtpDirectory get rootDirectory => FtpDirectory(
        path: _rootPath,
        client: _client,
      );

  Future<bool> testDirectory(String path) async {
    final currentPath = _currentDirectory.path;
    bool testResult = false;
    try {
      testResult = await changeDirectory(path);
    } finally {
      if (testResult) {
        await changeDirectory(currentPath);
      }
    }
    return testResult;
  }

  Future<bool> changeDirectory(String path) async {
    if (path == '..') {
      return await changeDirectoryUp();
    }
    final response = await FtpCommand.CWD.writeAndRead(_client.socket, [path]);
    if (response.isSuccessful) {
      _currentDirectory = FtpDirectory(
        path: path.startsWith(_rootPath) ? path : '$_rootPath$path',
        client: _client,
      );
      return true;
    }
    return false;
  }

  Future<bool> changeDirectoryUp() async {
    if (isRoot(_currentDirectory)) {
      return false;
    }
    final response = await FtpCommand.CDUP.writeAndRead(_client.socket);
    if (response.isSuccessful) {
      _currentDirectory = _currentDirectory.parent;
      return true;
    }
    return false;
  }

  Future<bool> changeDirectoryRoot() async {
    final response =
        await FtpCommand.CWD.writeAndRead(_client.socket, [_rootPath]);
    if (response.isSuccessful) {
      _currentDirectory = rootDirectory;
      return true;
    }
    return false;
  }

  Future<bool> changeDirectoryHome() async {
    final response = await FtpCommand.CWD.writeAndRead(_client.socket, ['~']);
    if (response.isSuccessful) {
      _currentDirectory = rootDirectory;
      return true;
    }
    return false;
  }

  Future<List<FtpEntry>> listDirectory({
    FtpDirectory? directory,
    ListType? override,
    FtpDirectory? realDirectory,
  }) async {
    final listType = override ?? this.listType;
    final dir = directory ?? _currentDirectory;
    final result = await _client.socket
        .openTransferChannel<List<FtpEntry>>((socketFuture, log) async {
      listType.command.write(_client.socket, [dir.path]);
      //will be closed by the transfer channel
      // ignore: close_sinks
      final socket = await socketFuture();
      final response = await _client.socket.readAll();
      if (response.isEmpty) {
        throw FtpException('Error while listing directory');
      }

      // wait 125 || 150 and >200 that indicates the end of the transfer
      final bool transferCompleted = response[0].isSuccessfulForDataTransfer;
      if (!transferCompleted) {
        if (response[0].code == 500 && listType == ListType.MLSD) {
          throw FtpException('MLSD command not supported by server');
        }
        throw FtpException('Error while listing directory');
      }
      final List<int> data = [];
      await socket.listen(data.addAll).asFuture();
      final listData = utf8.decode(data, allowMalformed: true);
      log?.call(listData);
      final parseListDirResponse = DataParserUtils.parseListDirResponse(
          listData, listType, realDirectory ?? dir);
      var mainPath = realDirectory?.path ?? dir.path;
      if (mainPath.endsWith('/')) {
        mainPath = mainPath.substring(0, mainPath.length - 1);
      }
      final remappedEntries = parseListDirResponse.map((e, v) {
        if (e is FtpDirectory) {
          return MapEntry(e.copyWith('${mainPath}/${e.name}', info: v), v);
        } else if (e is FtpFile) {
          return MapEntry(e.copyWith('${mainPath}/${e.name}', info: v), v);
        } else if (e is FtpLink) {
          return MapEntry(
              e.copyWith('${mainPath}/${e.name}', e.linkTargetPath, info: v),
              v);
        } else {
          throw FtpException('Unknown type');
        }
      });
      _dirInfoCache
          .add(MapEntry(mainPath, remappedEntries.entries.whereType()));
      if (response.length <= 1) {
        await _client.socket.read();
      }
      return remappedEntries.keys.toList();
    });
    return result;
  }

  Future<List<String>> listDirectoryNames([FtpDirectory? directory]) =>
      _client.socket
          .openTransferChannel<List<String>>((socketFuture, log) async {
        FtpCommand.NLST.write(
          _client.socket,
          [directory?.path ?? _currentDirectory.path],
        );
        final response = await _client.socket.readAll();
        final bool transferCompleted = response[0].isSuccessfulForDataTransfer;
        if (!transferCompleted) {
          throw FtpException('Error while listing directory names');
        }

        //will be closed by the transfer channel
        // ignore: close_sinks
        final socket = await socketFuture();

        final List<int> data = [];
        await socket.listen(data.addAll).asFuture();
        final listData = utf8.decode(data, allowMalformed: true);
        log?.call(listData);
        if (response.length <= 1) {
          await _client.socket.read();
        }
        return listData
            .split('\n')
            .map((e) => e.trim())
            .where((element) => element.isNotEmpty)
            .toList();
      });

  Stream<List<int>> downloadFileStream(FtpFile file,
          {void Function(int s)? onProcess,
          FtpSocketCancelToken? cancelToken,
          int restSize = 0,
          int speed = 0}) =>
      _transfer.downloadFileStream(file,
          onProcess: onProcess,
          restSize: restSize,
          speed: speed,
          cancelToken: cancelToken);

  Future<List<int>> downloadFile(FtpFile file,
      {void Function(int s)? onProcess,
      FtpSocketCancelToken? cancelToken}) async {
    final result = <int>[];
    await downloadFileStream(file,
            onProcess: onProcess, cancelToken: cancelToken)
        .listen(result.addAll)
        .asFuture();
    return result;
  }

  Future<bool> uploadFile(FtpFile file, List<int> data,
      {UploadChunkSize chunkSize = UploadChunkSize.kb4,
      void Function(int s)? onProcess}) async {
    final stream = StreamController<List<int>>();
    var result = false;
    try {
      final future =
          uploadFileFromStream(file, stream.stream, onProcess: onProcess);
      if (data.isEmpty) {
        stream.add(data);
      } else {
        for (var i = 0; i < data.length; i += chunkSize.value) {
          final end = i + chunkSize.value;
          final chunk = data.sublist(i, end > data.length ? data.length : end);
          stream.add(chunk);
        }
      }
      await stream.close();
      result = await future;
    } finally {
      await stream.close();
    }
    return result;
  }

  Future<FtpEntryInfo?> getEntryInfo(FtpEntry entry,
      {bool fromCache = true}) async {
    assert(
        entry.path != rootDirectory.path, 'Cannot get info for root directory');
    if (fromCache) {
      final cached =
          _dirInfoCache.firstWhereOrNull((e) => e.key == entry.parent.path);
      if (cached != null) {
        final r =
            cached.value.firstWhereOrNull((e) => e.key.name == entry.name);
        if (r != null) {
          return r.value;
        }
      }
    }
    try {
      if (entry is FtpFile) {
        final lr = await listDirectory(
            directory: FtpDirectory(path: entry.path, client: _client));
        if (lr.isNotEmpty) {
          return lr[0].info;
        }
      }
    } catch (e) {
      return null;
    }

    //todo: finish it
    // final dir = entry.parent;
    // final entries = await listDirectory(directory: dir);
    return null;
  }

  Future<bool> uploadFileFromStream(FtpFile file, Stream<List<int>> stream,
      {void Function(int s)? onProcess,
      bool isAppend = false,
      FtpSocketCancelToken? cancelToken}) async {
    return _transfer.uploadFileStream(file, stream,
        onProcess: onProcess, isAppend: isAppend, cancelToken: cancelToken);
  }

  FtpFileSystem copy() {
    final ftpFileSystem = FtpFileSystem(client: _client.clone());
    ftpFileSystem._currentDirectory = _currentDirectory;
    ftpFileSystem._rootPath = _rootPath;
    ftpFileSystem.listType = listType;
    return ftpFileSystem;
  }

  void clearCache() {
    _dirInfoCache.clear();
  }
}

enum ListType {
  LIST(FtpCommand.LIST),
  MLSD(FtpCommand.MLSD),
  ;

  final FtpCommand command;

  const ListType(this.command);
}

enum UploadChunkSize {
  kb1(1024),
  kb2(2048),
  kb4(4096),
  mb1(1024 * 1024),
  mb2(2 * 1024 * 1024),
  mb4(4 * 1024 * 1024),
  ;

  final int value;

  const UploadChunkSize(this.value);

  @override
  String toString() => 'UploadChunkSize(${value}b)';
}
