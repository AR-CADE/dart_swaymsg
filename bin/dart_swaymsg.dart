import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:i3_ipc/i3_ipc.dart';
import 'package:on_exit/init.dart';

const String dartSwayMsgVersion = '2.0';

const String usage = 'Usage: wf-msg [options] [message]\n'
    '\n'
    '  -h, --help             Show help message and quit.\n'
    '  -m, --monitor          Monitor until killed (-t SUBSCRIBE only)\n'
    '  -p, --pretty           Use pretty output even when not using a tty\n'
    '  -q, --quiet            Be quiet.\n'
    '  -r, --raw              Use raw output even if using a tty\n'
    '  -s, --socket <socket>  Use the specified socket.\n'
    '  -t, --type <type>      Specify the message type.\n'
    '  -v, --version          Show the version number and quit.\n';

bool parserDefaultValueForFlag(
  String name, {
  required String? abbr,
  required List<String> args,
}) {
  return (args.firstWhere(
        (arg) => arg == '--$name' || (abbr != null && arg == '-$abbr'),
        orElse: () => jsonEncode(null),
      ) !=
      jsonEncode(null));
}

void parserSetFlag(
  String name, {
  required ArgParser parser,
  required List<String> args,
  String? abbr,
}) {
  parser.addFlag(
    name,
    abbr: abbr,
    defaultsTo: parserDefaultValueForFlag(name, abbr: abbr, args: args),
  );
}

bool parserIsFlagSet(String name, {required ArgParser parser}) {
  final option = parser.findByNameOrAlias(name);
  final value = option?.valueOrDefault(null);
  return value != null && value is bool && value == true;
}

void help() {
  stderr.write(usage);
  exit(1);
}

void version() {
  stdout.writeln('dswaymsg version $dartSwayMsgVersion');
  exit(0);
}

void main(List<String> args) {
  var quiet = false;
  var raw = !stdout.hasTerminal;
  var monitor = false;
  String? socketPath;
  String? cmdtype;

  final parser = ArgParser()
    ..addOption('socket', abbr: 's')
    ..addOption('type', abbr: 't');
  parserSetFlag('monitor', abbr: 'm', parser: parser, args: args);
  parserSetFlag('pretty', abbr: 'p', parser: parser, args: args);
  parserSetFlag('quiet', abbr: 'q', parser: parser, args: args);
  parserSetFlag('raw', abbr: 'r', parser: parser, args: args);
  parserSetFlag('help', abbr: 'h', parser: parser, args: args);
  parserSetFlag('version', abbr: 'v', parser: parser, args: args);

  ArgResults results;
  try {
    results = parser.parse(args);
  } catch (e) {
    stderr.writeln(e);
    exit(1);
  }

  for (var i = 0; i < results.options.length; i++) {
    final name = results.options.elementAt(i);

    switch (name) {
      case 'monitor':
        {
          // Monitor
          if (parserIsFlagSet(name, parser: parser)) {
            monitor = true;
          }
          break;
        }

      case 'pretty':
        {
          // Pretty
          if (parserIsFlagSet(name, parser: parser)) {
            raw = false;
          }
          break;
        }
      case 'quiet':
        {
          // Quiet
          if (parserIsFlagSet(name, parser: parser)) {
            quiet = true;
          }
          break;
        }

      case 'raw':
        {
          // Raw
          if (parserIsFlagSet(name, parser: parser)) {
            raw = true;
          }
          break;
        }

      case 'socket':
        {
          // Socket
          socketPath = results['socket'] as String?;
          break;
        }

      case 'type':
        {
          // Type
          cmdtype = results['type'] as String?;
          break;
        }

      case 'version':
        {
          if (parserIsFlagSet(name, parser: parser)) {
            version();
          }
          break;
        }

      case 'help':
        {
          if (parserIsFlagSet(name, parser: parser)) {
            help();
          }
          break;
        }

      default:
        help();
    }
  }

  cmdtype ??= 'command';

  var type = IpcPayloadType.ipcCommand;

  cmdtype = cmdtype.toLowerCase();

  if (cmdtype == 'command') {
    type = IpcPayloadType.ipcCommand;
  } else if (cmdtype == 'get_workspaces') {
    type = IpcPayloadType.ipcGetWorkspaces;
  } else if (cmdtype == 'get_seats') {
    type = IpcPayloadType.ipcGetSeats;
  } else if (cmdtype == 'get_inputs') {
    type = IpcPayloadType.ipcGetInputs;
  } else if (cmdtype == 'get_outputs') {
    type = IpcPayloadType.ipcGetOutputs;
  } else if (cmdtype == 'get_tree') {
    type = IpcPayloadType.ipcGetTree;
  } else if (cmdtype == 'get_marks') {
    type = IpcPayloadType.ipcGetMarks;
  } else if (cmdtype == 'get_bar_config') {
    type = IpcPayloadType.ipcGetBarConfig;
  } else if (cmdtype == 'get_version') {
    type = IpcPayloadType.ipcGetVersion;
  } else if (cmdtype == 'get_binding_modes') {
    type = IpcPayloadType.ipcGetBindingModes;
  } else if (cmdtype == 'get_binding_state') {
    type = IpcPayloadType.ipcGetBindingState;
  } else if (cmdtype == 'get_config') {
    type = IpcPayloadType.ipcGetConfig;
  } else if (cmdtype == 'send_tick') {
    type = IpcPayloadType.ipcSendTick;
  } else if (cmdtype == 'subscribe') {
    type = IpcPayloadType.ipcSubscribe;
  } else {
    if (quiet) {
      exit(1);
    }
    stderr.writeln('Unknown message type $cmdtype');
    exit(1);
  }

  if (monitor && (type != IpcPayloadType.ipcSubscribe)) {
    if (!quiet) {
      stderr.writeln('Monitor can only be used with -t SUBSCRIBE');
    }

    exit(1);
  }

  String? command;

  if (results.rest.isNotEmpty) {
    command = results.rest.join(' ');
  }

  final i3CommandRepository = I3IpcCommandRepository();
  final bloc = I3ClientBloc(i3CommandRepository: i3CommandRepository);
  StreamSubscription<I3ClientBlocState>? subscription;
  Future.microtask(() async {
    bloc.add(
      I3IpcExecuteRequested(
        type: type,
        payload: command ?? '',
        socketPath: socketPath,
      ),
    );

    if (type != IpcPayloadType.ipcSubscribe) {
      final value = await bloc.stream.first;

      final response = value.response;
      final payload = response?.payload;

      if (payload == null) {
        if (!quiet) {
          stderr.writeln('failed to get payload');
        }

        await bloc.close();
        i3CommandRepository.close();
        exit(1);
      } else {
        if (!quiet) {
          if (raw) {
            stdout.writeln(PrettyPrinter.rawPretty(jsonDecode(payload)));
          } else if (response != null) {
            PrettyPrinter.prettyPrint(type, response);
          }
        }
      }

      await bloc.close();
      i3CommandRepository.close();
      exit(0);
    } else {
      stdout.writeln('Monitoring. ');

      subscription = bloc.stream.listen((value) async {
        final response = value.response;
        final payload = response?.payload;

        if (payload == null) {
          if (!quiet) {
            stderr.writeln('failed to get payload');
          }

          await bloc.close();
          i3CommandRepository.close();
          exit(1);
        } else if (quiet) {
          //
        } else {
          if (raw) {
            stdout.writeln(payload);
          } else {
            stdout.writeln(PrettyPrinter.rawPretty(jsonDecode(payload)));
          }
        }
      });
    }
  });

  onExit(() async {
    await subscription?.cancel();
    await bloc.close();
    i3CommandRepository.close();
  });
}
