import 'package:pure_ftp/src/extensions/ftp_directory_extensions.dart';
import 'package:pure_ftp/src/file_system/ftp_entry.dart';
import 'package:pure_ftp/src/file_system/ftp_entry_info.dart';
import 'package:pure_ftp/src/ftp/exceptions/ftp_exception.dart';
import 'package:pure_ftp/src/ftp/extensions/ftp_command_extension.dart';
import 'package:pure_ftp/src/ftp/ftp_commands.dart';
import 'package:pure_ftp/src/ftp_client.dart';

class FtpDirectory extends FtpEntry {
  final FtpClient _client;

  const FtpDirectory({
    required super.path,
    required super.client,
    super.info,
  }) : _client = client;

  @override
  FtpDirectory get parent {
    if (isRoot) {
      throw FtpException('Root directory has no parent');
    }
    return super.parent;
  }

  @override
  bool get isDirectory => true;

  bool get isRoot => _client.fs.isRoot(this);

  @override
  String get path => super.path.isEmpty ? '/' : super.path;

  @override
  Future<bool> exists() async {
    final response = await FtpCommand.CWD.writeAndRead(_client.socket, [path]);
    if (path != _client.currentDirectory.path) {
      await FtpCommand.CWD
          .writeAndRead(_client.socket, [_client.currentDirectory.path]);
    }
    return response.isSuccessful;
  }

  Future<bool> cwd() async {
    final response = await FtpCommand.CWD.writeAndRead(_client.socket, [path]);
    return response.isSuccessful;
  }

  Future<bool> cwdCurrent() async {
    final response = await FtpCommand.CWD
        .writeAndRead(_client.socket, [_client.currentDirectory.path]);
    return response.isSuccessful;
  }

  @override
  Future<bool> create({bool recursive = false}) async {
    var ret = await mkDirAll();
    await cwdCurrent();
    return ret;
  }

  Future<bool> mkDirAll() async {
    if (await cwd()) {
      return true;
    }

    var pret = await parent.mkDirAll();
    if (!pret) {
      return pret;
    }

    final response = await FtpCommand.MKD.writeAndRead(_client.socket, [path]);
    return response.isSuccessful;
  }

  @override
  Future<bool> delete({bool recursive = false}) async {
    if (!await exists()) {
      return true;
    }
    if (recursive) {
      // final resp = await FtpCommand.RMDA.writeAndRead(_client.socket, [path]);
      // if (resp.isSuccessful) {
      //   return true;
      // }
      final children = await list();
      for (var f in children) {
        final resp = await f.delete(recursive: true);
        if (!resp) {
          return false;
        }
      }

      final hideChildren = await _client.fs.listDirectory(
          directory: this.getChildDir(".*"), realDirectory: this);
      for (var f in hideChildren) {
        if (f.name != "." && f.name != "..") {
          final resp = await f.delete(recursive: true);
          if (!resp) {
            return false;
          }
        }
      }
    }
    final response = await FtpCommand.RMD.writeAndRead(_client.socket, [path]);
    //todo remove recursive if is not empty
    return response.isSuccessful;
  }

  @override
  Future<FtpDirectory> rename(String newName) async {
    if (isRoot) {
      throw FtpException('Cannot rename root directory');
    }
    if (newName.contains('/')) {
      throw FtpException('New name cannot contain path separator');
    }
    if (!await exists()) {
      throw FtpException('Directory does not exist');
    }
    var response = await FtpCommand.RNFR.writeAndRead(_client.socket, [path]);
    if (response.code != 350) {
      throw FtpException('Could not rename directory');
    }

    final newPath = parent.getChildDir(newName).path;
    response = await FtpCommand.RNTO.writeAndRead(_client.socket, [
      newPath,
    ]);
    if (!response.isSuccessful) {
      throw FtpException('Could not rename directory');
    }
    return FtpDirectory(path: newPath, client: _client);
  }

  @override
  Future<bool> copy(String newPath) async {
    if (!await exists()) {
      return false;
    }
    //todo implements copy
    return false;
  }

  @override
  Future<FtpDirectory> move(String newPath) async {
    if (!await exists()) {
      throw FtpException('Directory does not exist');
    }
    if (newPath == path) {
      return this;
    }
    if (!newPath.startsWith('/')) {
      throw FtpException(
          'New path must be absolute, to rename use rename(new name)');
    }
    final newDirectory = FtpDirectory(path: newPath, client: _client).parent;
    if (!await newDirectory.exists()) {
      throw FtpException('directory does not exist: ${newDirectory.path}');
    }
    var response = await FtpCommand.RNFR.writeAndRead(_client.socket, [path]);
    if (response.code != 350) {
      throw FtpException('Could not move directory');
    }
    response = await FtpCommand.RNTO.writeAndRead(_client.socket, [
      newPath,
    ]);
    if (!response.isSuccessful) {
      throw FtpException('Could not move directory');
    }
    return FtpDirectory(path: newPath, client: _client);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is FtpDirectory &&
        other.path == path &&
        other._client == _client;
  }

  @override
  int get hashCode => path.hashCode ^ _client.hashCode;

  Future<List<FtpEntry>> list() => _client.fs.listDirectory(directory: this);

  Future<List<String>> listNames() => _client.fs.listDirectoryNames(this);

  FtpDirectory copyWith(String path, {FtpEntryInfo? info}) {
    return FtpDirectory(
      path: path,
      info: info,
      client: _client,
    );
  }

  @override
  String toString() {
    return 'FtpDirectory(path: $path)';
  }
}
