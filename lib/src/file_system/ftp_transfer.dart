import 'dart:async';
import 'dart:typed_data';

import 'package:pure_ftp/src/file_system/entries/ftp_file.dart';
import 'package:pure_ftp/src/ftp/exceptions/ftp_exception.dart';
import 'package:pure_ftp/src/ftp/extensions/ftp_command_extension.dart';
import 'package:pure_ftp/src/ftp/ftp_commands.dart';
import 'package:pure_ftp/src/ftp/ftp_socket.dart';
import 'package:pure_ftp/src/socket/common/client_raw_socket.dart';
import 'package:pure_ftp/src/ftp/ftp_response.dart';

class FtpTransfer {
  final FtpSocket _socket;

  FtpTransfer({
    required FtpSocket socket,
  }) : _socket = socket;

  Stream<List<int>> downloadFileStream(
    FtpFile file, {
    void Function(int s)? onProcess,
    FtpSocketCancelToken? cancelToken,
    int restSize = 0,
    int speed = 0,
  }) {
    final stream = StreamController<List<int>>();
    unawaited(_socket.openTransferChannel((socketFuture, log) async {
      if (restSize > 0) {
        await FtpCommand.TYPE
            .writeAndRead(_socket, [FtpTransferType.binary.type]);
        final ret = await FtpCommand.REST.writeAndRead(_socket, ['$restSize']);
        if (ret.code >= 400) {
          throw FtpException(ret.message);
        }
      }
      FtpCommand.RETR.write(
        _socket,
        [file.path],
      );
      //will be closed by the transfer channel
      // ignore: close_sinks
      final socket = await socketFuture();
      final response = await _socket.readAll();

      // wait 125 || 150 and >200 that indicates the end of the transfer
      final bool transferCompleted = response[0].isSuccessfulForDataTransfer;
      if (!transferCompleted) {
        throw FtpException('Error while downloading file');
      }
      var total = 0;
      final List<int> cacheBuffer = [];

      void addToStream(List<int> value) {
        if (value.isEmpty) {
          return;
        }
        stream.add(value);
        total += value.length;
        if (onProcess != null) {
          onProcess(total);
        }
        log?.call('Downloaded ${total} bytes ');
      }

      Future<void> addToStreamLimit(List<int> value) async {
        if (cancelToken != null && cancelToken.isCancel) {
          await stream.close();
          return;
        }
        var len = speed - cacheBuffer.length;
        List<int>? notAddValue;
        if (value.length <= len) {
          cacheBuffer.addAll(value);
        } else {
          cacheBuffer.addAll(value.sublist(0, len));
          notAddValue = value.sublist(len);
        }
        if (cacheBuffer.length >= speed) {
          addToStream([...cacheBuffer]);
          cacheBuffer.clear();
          await Future.delayed(const Duration(seconds: 1));
        }
        if (notAddValue != null) {
          await addToStreamLimit(notAddValue);
        }
      }

      var subscription = socket.listen(
        null,
      );

      Future<void> add(List<int> value) async {
        if (speed <= 0) {
          addToStream(value);
          return;
        }

        await addToStreamLimit(value);
      }

      final resume = subscription.resume;
      subscription.onData((event) {
        subscription.pause();
        add(event).whenComplete(resume);
      });
      stream.onCancel = subscription.cancel;
      stream
        ..onPause = subscription.pause
        ..onResume = resume;
      await subscription.asFuture();
      addToStream(cacheBuffer);
      await stream.close();
      if (cancelToken?.isCancel != true) {
        if (response.length <= 1) {
          await _socket.read();
        }
      }
    }, (error, stackTrace) {
      throw Exception(error);
      // stream.addError(error, stackTrace);
      // stream.close();
    }, cancelToken));
    return stream.stream;
  }

  Future<bool> uploadFileStream(FtpFile file, Stream<List<int>> data,
      {void Function(int s)? onProcess,
      bool isAppend = false,
      FtpSocketCancelToken? cancelToken}) async {
    return _socket.openTransferChannel((socketFuture, log) async {
      if (isAppend) {
        FtpCommand.APPE.write(
          _socket,
          [file.path],
        );
      } else {
        FtpCommand.STOR.write(
          _socket,
          [file.path],
        );
      }

      final response = await _socket.readAll();

      // wait 125 || 150 and >200 that indicates the end of the transfer
      final bool transferCompleted = response[0].isSuccessfulForDataTransfer;
      if (!transferCompleted) {
        throw FtpException(response[0].message);
      }
      final socket = await socketFuture();

      var total = 0;
      final transform = data.transform<Uint8List>(
        StreamTransformer.fromHandlers(
          handleData: (event, sink) {
            sink.add(Uint8List.fromList(event));
            total += event.length;
            if (onProcess != null) {
              onProcess(total);
            }
            log?.call('Uploaded ${total} bytes');
          },
        ),
      );
      await socket.addSteam(transform);
      await socket.flush;
      await socket.close(ClientSocketDirection.readWrite);
      final isCanceled = cancelToken?.isCancel == true;
      if (response.length <= 1 && !isCanceled) {
        await _socket.read();
      }
      return true;
    }, (error, stackTrace) {
      throw error;
    }, cancelToken);
  }
}
