import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:i3_ipc/i3_ipc.dart';
import 'package:on_exit/init.dart';

const String dartSwayMsgVersion = "1.0";

const String usage = "Usage: wf-msg [options] [message]\n"
    "\n"
    "  -h, --help             Show help message and quit.\n"
    "  -m, --monitor          Monitor until killed (-t SUBSCRIBE only)\n"
    "  -p, --pretty           Use pretty output even when not using a tty\n"
    "  -q, --quiet            Be quiet.\n"
    "  -r, --raw              Use raw output even if using a tty\n"
    "  -s, --socket <socket>  Use the specified socket.\n"
    "  -t, --type <type>      Specify the message type.\n"
    "  -v, --version          Show the version number and quit.\n"
    "  -b, --big-endian       Use big endian to communicate with the server (Default: Little endian).\n";

bool parserDefaultValueForFlag(String name,
    {required String? abbr, required List<String> args}) {
  return (args.firstWhere(
          (arg) => arg == "--$name" || (abbr != null ? arg == "-$abbr" : false),
          orElse: () => jsonEncode(null)) !=
      jsonEncode(null));
}

void parserSetFlag(String name,
    {required ArgParser parser, String? abbr, required List<String> args}) {
  parser.addFlag(
    name,
    abbr: abbr,
    defaultsTo: parserDefaultValueForFlag(name, abbr: abbr, args: args),
  );
}

bool parserIsFlagSet(String name, {required ArgParser parser}) {
  Option? option = parser.findByNameOrAlias(name);
  final value = option?.valueOrDefault(null);
  return (value != null && value is bool && value == true);
}

void help() {
  stderr.write(usage);
  exit(1);
}

void version() {
  stdout.writeln("dswaymsg version $dartSwayMsgVersion");
  exit(0);
}

Future<void> main(List<String> args) async {
  bool quiet = false;
  bool raw = false;
  bool monitor = false;
  String? socketPath;
  String? cmdtype;
  Endian endian = Endian.little;

  final parser = ArgParser();
  parser.addOption('socket', abbr: 's');
  parser.addOption('type', abbr: 't');
  parserSetFlag('monitor', abbr: 'm', parser: parser, args: args);
  parserSetFlag('pretty', abbr: 'p', parser: parser, args: args);
  parserSetFlag('quiet', abbr: 'q', parser: parser, args: args);
  parserSetFlag('raw', abbr: 'r', parser: parser, args: args);
  parserSetFlag('help', abbr: 'h', parser: parser, args: args);
  parserSetFlag('version', abbr: 'v', parser: parser, args: args);
  parserSetFlag('big-endian', abbr: 'b', parser: parser, args: args);

  ArgResults results;
  try {
    results = parser.parse(args);
  } catch (e) {
    stderr.writeln(e);
    exit(1);
  }

  for (var i = 0; i < results.options.length; i++) {
    String name = results.options.elementAt(i);

    switch (name) {
      case 'monitor': // Monitor
        if (parserIsFlagSet(name, parser: parser)) {
          monitor = true;
        }
        break;

      case 'pretty': // Pretty
        if (parserIsFlagSet(name, parser: parser)) {
          raw = false;
        }
        break;

      case 'quiet': // Quiet
        if (parserIsFlagSet(name, parser: parser)) {
          quiet = true;
        }
        break;

      case 'raw': // Raw
        if (parserIsFlagSet(name, parser: parser)) {
          raw = true;
        }
        break;

      case 'socket': // Socket
        socketPath = results["socket"];
        break;

      case 'type': // Type
        cmdtype = results["type"];
        break;

      case 'version':
        if (parserIsFlagSet(name, parser: parser)) {
          version();
        }
        break;

      case 'big-endian':
        if (parserIsFlagSet(name, parser: parser)) {
          endian = Endian.big;
        }
        break;

      case 'help':
        if (parserIsFlagSet(name, parser: parser)) {
          help();
        }
        break;

      default:
        help();
    }
  }

  cmdtype ??= "command";

  if (socketPath == null) {
    socketPath = IPCClient.getSocketpath();
    if (socketPath == null) {
      if (quiet) {
        exit(1);
      }
      IPCClient.clientAbort(null, "Unable to retrieve socket path");
    }
  }

  var type = IPCPayloadType.ipcCommand;

  cmdtype = cmdtype.toLowerCase();

  if (cmdtype == "command") {
    type = IPCPayloadType.ipcCommand;
  } else if (cmdtype == "get_workspaces") {
    type = IPCPayloadType.ipcGetWorkspaces;
  } else if (cmdtype == "get_seats") {
    type = IPCPayloadType.ipcGetSeats;
  } else if (cmdtype == "get_inputs") {
    type = IPCPayloadType.ipcGetInputs;
  } else if (cmdtype == "get_outputs") {
    type = IPCPayloadType.ipcGetOutputs;
  } else if (cmdtype == "get_tree") {
    type = IPCPayloadType.ipcGetTree;
  } else if (cmdtype == "get_marks") {
    type = IPCPayloadType.ipcGetMarks;
  } else if (cmdtype == "get_bar_config") {
    type = IPCPayloadType.ipcGetBarConfig;
  } else if (cmdtype == "get_version") {
    type = IPCPayloadType.ipcGetVersion;
  } else if (cmdtype == "get_binding_modes") {
    type = IPCPayloadType.ipcGetBindingModes;
  } else if (cmdtype == "get_binding_state") {
    type = IPCPayloadType.ipcGetBindingState;
  } else if (cmdtype == "get_config") {
    type = IPCPayloadType.ipcGetConfig;
  } else if (cmdtype == "send_tick") {
    type = IPCPayloadType.ipcSendTick;
  } else if (cmdtype == "subscribe") {
    type = IPCPayloadType.ipcSubscribe;
  } else {
    if (quiet) {
      exit(1);
    }

    IPCClient.clientAbort(null, "Unknown message type $cmdtype");
  }

  if (monitor && (type != IPCPayloadType.ipcSubscribe)) {
    if (!quiet) {
      stderr.writeln("Monitor can only be used with -t SUBSCRIBE");
    }

    exit(1);
  }

  String? command;

  if (results.rest.isNotEmpty) {
    command = StringTools.joinArgs(results.rest);
  }

  int ret = 0;
  final controller = (type == IPCPayloadType.ipcSubscribe)
      ? StreamController<IPCResponse?>.broadcast()
      : StreamController<IPCResponse?>();
  IPCClient.singleCommand(type,
      payload: command ?? "",
      controller: controller,
      endian: endian,
      socketPath: socketPath);
  final stream = (type == IPCPayloadType.ipcSubscribe)
      ? controller.stream.asBroadcastStream()
      : controller.stream;

  final resp = await stream.first;
  if (type != IPCPayloadType.ipcSubscribe) {
    controller.close();
  }
  dynamic result = resp?.toJson();

  if (result == null || result.length == 0) {
    if (!quiet) {
      final String err = resp != null ? resp.toString() : "";
      stderr.writeln("failed to parse payload as json: $err");
    }

    ret = 1;
  } else {
    if (!Status.success(result, true)) {
      ret = 2;
    }

    if (!quiet && ((type != IPCPayloadType.ipcSubscribe) || (ret != 0))) {
      if (raw) {
        print(resp);
      } else {
        PrettyPrinter.prettyPrint(type, result);
      }
    }
  }

  if ((type == IPCPayloadType.ipcSubscribe) && (ret == 0)) {
    stdout.writeln("Monitoring. ");

    stream.listen((reply) {
      dynamic obj = reply?.toJson();
      if (obj == null) {
        if (!quiet) {
          stderr.writeln("failed to parse payload as json: $resp");
        }

        ret = 1;
        controller.close();
        return;
      } else if (quiet) {
        //
      } else {
        if (raw) {
          print(obj);
        } else {
          print(PrettyPrinter.prettyJson(obj));
        }
      }
    });

    onExit(() {
      controller.close();
    });
  }
}
