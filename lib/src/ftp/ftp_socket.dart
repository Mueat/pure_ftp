// ignore_for_file: constant_identifier_names

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:meta/meta.dart';
import 'package:pure_ftp/src/ftp/exceptions/ftp_exception.dart';
import 'package:pure_ftp/src/ftp/extensions/ftp_command_extension.dart';
import 'package:pure_ftp/src/ftp/ftp_commands.dart';
import 'package:pure_ftp/src/ftp/ftp_response.dart';
import 'package:pure_ftp/src/ftp/utils/data_parser_utils.dart';
import 'package:pure_ftp/src/ftp_client.dart';
import 'package:pure_ftp/src/socket/common/client_raw_socket.dart';
import 'package:pure_ftp/src/socket/common/client_socket.dart';
import 'package:pure_ftp/src/socket/common/host_server.dart';
import 'package:pure_ftp/src/socket/common/web_io_network_address.dart';

typedef TransferChannelCallback<T> = FutureOr<T> Function(
    FutureOr<ClientSocket> Function() socketFuture, LogCallback? log);
typedef TransferFailCallback = FutureOr<void> Function(
    Object error, StackTrace stackTrace);

class FtpSocket {
  final String _host;
  final int _port;
  final Duration _timeout;
  final void Function(dynamic message)? _log;
  final SecurityType _securityType;
  bool supportIPv6;
  FtpTransferMode transferMode;
  FtpTransferType _transferType;

  late ClientRawSocket _socket;
  int? passivePort;

  FtpSocket({
    required FtpSocketInitOptions options,
    LogCallback? logCallback,
  })  : _host = options.host,
        _port = options.port ??
            (options.securityType == SecurityType.FTPS ? 990 : 21),
        _timeout = options.timeout,
        _log = logCallback,
        transferMode = options.transferMode,
        _transferType = options.transferType,
        _securityType = options.securityType,
        supportIPv6 = options.supportIPv6;

  /// Connect to the FTP Server with given credentials
  ///
  /// and set the transfer mode
  Future<void> connect(String user, String pass, {String? account}) async {
    _log?.call(
        'Connecting to $_host:$_port with user:$user, pass:${'*' * pass.length}, account:$account');
    try {
      _socket = await ClientRawSocket.connect(
        _host,
        _port,
        timeout: _timeout,
      );
    } catch (e) {
      throw FtpException('Could not connect to $_host ($_port):\n$e');
    }
    _log?.call('Connected to $_host:$_port');
    // flush welcome message
    await read();

    // setup secure connection
    if (_securityType.isSecure) {
      if (_securityType.isExplicit) {
        if (!(await FtpCommand.AUTH.writeAndRead(this, ['TLS'])).isSuccessful) {
          if (!(await FtpCommand.AUTH.writeAndRead(this, ['SSL']))
              .isSuccessful) {
            throw FtpException(
                'FTPES cannot be applied: the server refused both AUTH TLS and AUTH SSL commands');
          }
        }
      }
      try {
        _socket = await _socket.secureSocket(ignoreCertificateErrors: true);
      } on FtpException {
        if (!_securityType.isExplicit) {
          throw FtpException('Check if the server supports implicit FTPS'
              ' and that port $_port is correct(990 for FTPS)');
        } else {
          rethrow;
        }
      }
      await FtpCommand.PBSZ.writeAndRead(this, ['0']);
      await FtpCommand.PROT.writeAndRead(this, ['P']);
    }

    var ftpResponse = await FtpCommand.USER.writeAndRead(this, [user]);
    final passwordRequired = ftpResponse.code == 331;
    if (passwordRequired) {
      ftpResponse = await FtpCommand.PASS.writeAndRead(this, [pass]);
    }
    if (ftpResponse.code == 332) {
      if (account == null) {
        throw FtpException('Account required');
      }
      ftpResponse = await FtpCommand.ACCT.writeAndRead(this, [account]);
      if (!ftpResponse.isSuccessful) {
        throw FtpException('Wrong Account');
      }
    }
    if (!passwordRequired && !ftpResponse.isSuccessful) {
      throw FtpException('Wrong Username');
    }
    if (!ftpResponse.isSuccessful) {
      throw FtpException('Wrong Username/password');
    }
    await FtpCommand.TYPE.writeAndRead(this, [_transferType.type]);
    _log?.call('Logged in');
  }

  /// Closes the connection
  ///
  /// if [safe] is true, the connection will be closed after the server has
  /// confirmed the close command(if the server supports it)
  Future<void> disconnect({bool safe = true}) async {
    _log?.call('Disconnecting from $_host:$_port');
    try {
      if (safe) {
        write(FtpCommand.QUIT.toString());
      }
    } catch (_) {
      // ignore
    } finally {
      await _socket.close();
      await _socket.shutdown(ClientSocketDirection.readWrite);
      _log?.call('Disconnected from $_host:$_port');
    }
  }

  Future<List<String>> readLines() async {
    final res = StringBuffer();
    await Future.doWhile(() async {
      bool dataReceivedSuccessfully = false;

      //this is used to read all data for specific command line
      while (_socket.available() > 0) {
        res.write(String.fromCharCodes(_socket.readMessage()!.toList()).trim());
        dataReceivedSuccessfully = true;
      }
      if (dataReceivedSuccessfully) {
        return false;
      }
      await Future.delayed(const Duration(milliseconds: 300));

      return true;
    }).timeout(_timeout, onTimeout: () {
      throw FtpException('Timeout reached for Receiving response!');
    });
    final result = res.toString().trimLeft();
    if (result.length < 3) {
      throw FtpException('Illegal Reply Exception');
    }
    final lines = result.split('\n');
    if (lines.isNotEmpty && lines.last.length >= 4 && lines.last[3] == '-') {
      return await readLines();
    }
    return lines;
  }

  Future<List<FtpResponse>> readAll({int? endCode}) async {
    final lines = await readLines();
    List<FtpResponse> ret = [];
    for (var line in lines) {
      _log?.call('[${DateTime.now().toString()}] $_host:$_port< $line');
      if (line.length >= 3) {
        var code = int.tryParse(line.substring(0, 3)) ?? -1;
        ret.add(FtpResponse(code: code, message: line));
      }
    }
    if (ret.isEmpty) {
      throw FtpException("Read response failed");
    }
    return ret;
  }

  /// Fetch the response from the server
  ///
  /// FtpSocket.timeout is the time to wait for the response
  Future<FtpResponse> read({int? endCode}) async {
    final res = StringBuffer();
    await Future.doWhile(() async {
      bool dataReceivedSuccessfully = false;

      //this is used to read all data for specific command line
      while (_socket.available() > 0) {
        res.write(String.fromCharCodes(_socket.readMessage()!.toList()).trim());
        dataReceivedSuccessfully = true;
      }
      if (dataReceivedSuccessfully) {
        return false;
      }
      await Future.delayed(const Duration(milliseconds: 300));

      return true;
    }).timeout(_timeout, onTimeout: () {
      throw FtpException('Timeout reached for Receiving response!');
    });
    final result = res.toString().trimLeft();
    if (result.length < 3) {
      throw FtpException('Illegal Reply Exception');
    }
    final lines = result.split('\n');

    if (lines.isNotEmpty && lines.last.length >= 4 && lines.last[3] == '-') {
      return await read();
    }

    var code = -1;
    for (var i = lines.length - 1; i >= 0; i--) {
      final line = lines[i];
      if (line.length >= 3) {
        code = int.tryParse(line.substring(0, 3)) ?? code;
        break;
      }
    }

    if (endCode != null && endCode != code) {
      return await read();
    }

    if (code == -1) {
      throw FtpException('Illegal Reply Exception');
    }

    _log?.call('[${DateTime.now().toString()}] $_host:$_port< $result');
    return FtpResponse(code: code, message: result);
  }

  /// Send message to the server
  ///
  /// if [command] is true then the message will be sent as a command
  void write(String message, {bool command = true}) {
    _socket.write(utf8.encode('$message${command ? '\r\n' : ''}'));
    if (message.startsWith(FtpCommand.PASS.toString())) {
      _log?.call(
          '$_host:$_port> ${message.substring(0, 5)}${'*' * (message.length - 4)}');
    } else {
      _log?.call('[${DateTime.now().toString()}] $_host:$_port> $message');
    }
  }

  /// Send message to the server and fetch the response
  ///
  /// instead of [write] this method will call [read] after sending the message
  /// and send only commands
  Future<FtpResponse> writeAndRead(String message) {
    write(message, command: true);
    return read();
  }

  FtpTransferType get transferType => _transferType;

  Future<void> setTransferType(FtpTransferType type) async {
    if (transferType == type) {
      return;
    }
    await FtpCommand.TYPE.writeAndRead(this, [type.type]);
    _transferType = type;
  }

  Future<int> getPassivePort() async {
    final passiveCommand = supportIPv6 ? FtpCommand.EPSV : FtpCommand.PASV;
    final ftpResponse = await passiveCommand.writeAndRead(this);
    if (!ftpResponse.isSuccessful) {
      throw FtpException(
          'Could not open transfer channel: ${ftpResponse.message}');
    }
    try {
      return DataParserUtils.parsePort(ftpResponse, isIPV6: supportIPv6);
    } catch (e) {
      throw FtpException(
          'Could not open transfer channel: ${ftpResponse.message}');
    }
  }

  /// 主动模式开启本地连接
  Future<HostServer> getActiveHostServer() async {
    final port = transferMode.port ?? Random().nextInt(10000) + 10000;
    final server =
        await HostServer.bind(WebIONetworkAddress.anyIPv4.host, port);
    _log?.call('Listening on ${server.address}:${server.port}');
    final ftpResponse = await FtpCommand.PORT.writeAndRead(this, [
      [
        transferMode.host!.replaceAll('.', ','),
        ((port >> 8) & 0xFF).toString(),
        (port & 0xFF).toString()
      ].join(',')
    ]);
    if (!ftpResponse.isSuccessful) {
      throw FtpException('Could not open transfer channel');
    }
    return server;
  }

  Future<T> openTransferChannel<T>(
    TransferChannelCallback doStuff, [
    TransferFailCallback? onFail,
    FtpSocketCancelToken? cancelToken,
  ]) async {
    if (transferMode == FtpTransferMode.passive) {
      final port = await getPassivePort();

      final ClientSocket dataSocket = await ClientSocket.connect(_host, port,
          timeout: const Duration(seconds: 3));
      if (cancelToken != null) {
        cancelToken.cancelFun = () async {
          await dataSocket.close(ClientSocketDirection.readWrite);
        };
      }
      T result;
      try {
        result = await doStuff(() => dataSocket, _log);
      } catch (e, s) {
        if (onFail != null) {
          await onFail(e, s);
        }
        rethrow;
      } finally {
        await dataSocket.close(ClientSocketDirection.readWrite);
      }
      return result;
    }
    //active mode
    final server = await getActiveHostServer();
    ClientSocket? socket;
    var isCanceled = false;
    if (cancelToken != null) {
      cancelToken.cancelFun = () async {
        isCanceled = true;
        await socket?.close(ClientSocketDirection.readWrite);
      };
    }
    T result;
    try {
      FutureOr<ClientSocket> getSocket() async {
        return server.firstSocket.then<ClientSocket>((value) {
          socket = value;
          return value;
        }).timeout(_timeout);
      }

      result = await doStuff(getSocket, _log);
    } catch (e, s) {
      if (onFail != null) {
        await onFail(e, s);
      }
      rethrow;
    } finally {
      // await FtpCommand.ABOR.writeAndRead(this);
      await server.close();
    }
    try {
      FtpCommand.ABOR.write(this);
      await this.readAll();
    } catch (e) {
      _log?.call(e.toString());
    }
    // await FtpCommand.ABOR.writeAndRead(this);
    return result;
  }

  FtpSocket copy() => FtpSocket(
        options: FtpSocketInitOptions(
          host: _host,
          port: _port,
          timeout: _timeout,
          securityType: _securityType,
          transferMode: transferMode,
          transferType: transferType,
          supportIPv6: supportIPv6,
        ),
        logCallback: _log,
      );
}

class FtpTransferMode {
  static const FtpTransferMode passive = FtpTransferMode._();
  final String? host;
  final int? port;

  /// Creates an active FtpTransferMode
  /// [host] is the host to connect from ftp server
  /// [port] is the port to use for the active mode
  /// if [port] is null a random port will be used
  ///
  /// if you want to use passive mode use [FtpTransferMode.passive]
  const FtpTransferMode.active({required this.host, this.port})
      : assert(port == null || port > 0);

  const FtpTransferMode._()
      : port = -1,
        host = null;
}

enum FtpTransferType {
  auto('A'),
  ascii('A'),
  binary('I'),
  ;

  final String type;

  const FtpTransferType(this.type);
}

enum SecurityType {
  FTP,
  FTPS,
  FTPES,
  ;

  bool get isSecure => this != SecurityType.FTP;

  bool get isExplicit => this == SecurityType.FTPES;
}

@immutable
class FtpSocketInitOptions {
  final String host;
  final int? port;
  final Duration timeout;
  final SecurityType securityType;
  final bool supportIPv6;
  final FtpTransferMode transferMode;
  final FtpTransferType transferType;

  const FtpSocketInitOptions({
    required this.host,
    this.port,
    this.timeout = const Duration(seconds: 30),
    this.securityType = SecurityType.FTP,
    this.supportIPv6 = false,
    this.transferMode = FtpTransferMode.passive,
    this.transferType = FtpTransferType.auto,
  });
}

class FtpSocketCancelToken {
  Future<void> Function()? cancelFun;

  bool isCancel = false;

  Future<void> cancel() async {
    isCancel = true;
    if (cancelFun != null) {
      await cancelFun!();
    }
  }
}
