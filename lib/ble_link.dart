import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Mesmos UUIDs do firmware (safebtn/src/main.c)
final Guid kSvcUuid = Guid('5a1b0001-7c3d-4e8f-9a2b-1c4d5e6f7a80');
final Guid kEvtUuid = Guid('5a1b0002-7c3d-4e8f-9a2b-1c4d5e6f7a80');
const String kDeviceName = 'SafeBtn';

/// Conexao BLE com o botao: procura, conecta, reconecta sozinho e entrega
/// cada evento (tipo, seq, uptime) decodificado.
///
/// Payload do botao (6 bytes, little-endian): tipo(u8) seq(u8) uptime_s(u32)
class BleLink {
  BleLink({
    required this.onLog,
    required this.onStatus,
    required this.onEvent,
  });

  final void Function(String msg) onLog;
  final void Function(String status) onStatus;
  final void Function(int tipo, int seq, int uptimeS) onEvent;

  static const _prefKey = 'ble_remote_id';

  bool _running = false;
  bool _settingUp = false;
  BluetoothDevice? _device;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _valSub;
  final Map<String, DateTime> _seen = {}; // descarta duplicados

  Future<void> start() async {
    if (_running) return;
    _running = true;
    onStatus('iniciando...');
    try {
      // O Bluetooth do celular precisa estar ligado.
      if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
        try {
          await FlutterBluePlus.turnOn(); // so Android; no iOS lança erro
        } catch (_) {}
      }
      await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .first
          .timeout(const Duration(seconds: 30));

      final prefs = await SharedPreferences.getInstance();
      final savedId = prefs.getString(_prefKey);
      BluetoothDevice? dev;
      if (savedId != null) {
        dev = BluetoothDevice.fromId(savedId);
        onLog('botão salvo: $savedId');
      }
      while (_running && dev == null) {
        onStatus('procurando o SafeBtn...');
        dev = await _scan();
        if (dev == null && _running) {
          await Future.delayed(const Duration(seconds: 8));
        }
      }
      if (!_running || dev == null) return;
      await prefs.setString(_prefKey, dev.remoteId.str);
      await _connect(dev);
    } on TimeoutException {
      onStatus('Bluetooth desligado');
      onLog('ligue o Bluetooth do celular');
      _running = false;
    } catch (e) {
      onStatus('erro');
      onLog('erro ao iniciar o Bluetooth: $e');
      _running = false;
    }
  }

  Future<BluetoothDevice?> _scan() async {
    final found = Completer<BluetoothDevice?>();
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        final byName = r.advertisementData.advName == kDeviceName;
        final bySvc = r.advertisementData.serviceUuids.contains(kSvcUuid);
        if ((byName || bySvc) && !found.isCompleted) {
          found.complete(r.device);
        }
      }
    }, onError: (Object e) => onLog('erro no scan: $e'));
    try {
      await FlutterBluePlus.startScan(
        withNames: [kDeviceName],
        timeout: const Duration(seconds: 20),
      );
      return await found.future
          .timeout(const Duration(seconds: 21), onTimeout: () => null);
    } catch (e) {
      onLog('scan falhou: $e');
      return null;
    } finally {
      await sub.cancel();
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
    }
  }

  Future<void> _connect(BluetoothDevice dev) async {
    _device = dev;
    await _connSub?.cancel();
    _connSub = dev.connectionState.listen((s) async {
      if (s == BluetoothConnectionState.connected) {
        onStatus('conectado, configurando...');
        await _setup(dev);
      } else if (s == BluetoothConnectionState.disconnected && _running) {
        onStatus('desconectado, reconectando...');
      }
    });
    onStatus('conectando...');
    // autoConnect: reconecta sozinho sempre que o botao reaparecer.
    // (com autoConnect o mtu precisa ser null)
    await dev.connect(
      license: License.nonprofit, // uso pessoal (licenca do flutter_blue_plus)
      autoConnect: true,
      mtu: null,
    );
  }

  /// Depois de CADA (re)conexao: descobrir servicos e assinar as indications.
  Future<void> _setup(BluetoothDevice dev) async {
    if (_settingUp) return;
    _settingUp = true;
    try {
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          final services = await dev.discoverServices();
          BluetoothCharacteristic? chr;
          for (final s in services) {
            if (s.uuid == kSvcUuid) {
              for (final c in s.characteristics) {
                if (c.uuid == kEvtUuid) chr = c;
              }
            }
          }
          if (chr == null) {
            onStatus('serviço do SafeBtn não encontrado');
            onLog('serviço não encontrado (firmware certo?)');
            return;
          }
          await _valSub?.cancel();
          _valSub = chr.onValueReceived.listen(_onData);
          dev.cancelWhenDisconnected(_valSub!);
          await chr.setNotifyValue(true); // o botao usa INDICATION
          onStatus('conectado (indications ativas)');
          onLog('botão conectado e assinado');
          return;
        } catch (e) {
          onLog('configuração falhou ($attempt/3): $e');
          await Future.delayed(const Duration(seconds: 2));
          if (!dev.isConnected) return;
        }
      }
      onStatus('falha ao configurar');
    } finally {
      _settingUp = false;
    }
  }

  void _onData(List<int> v) {
    if (v.length != 6) {
      onLog('payload inesperado: $v');
      return;
    }
    final tipo = v[0];
    final seq = v[1];
    final uptime = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);

    // o botao reenvia se a confirmacao se perder: descarta repetidos
    final now = DateTime.now();
    _seen.removeWhere((_, t) => now.difference(t).inMinutes >= 10);
    final key = '$tipo-$seq-$uptime';
    if (_seen.containsKey(key)) {
      onLog('(duplicado ignorado: tipo=$tipo seq=$seq)');
      return;
    }
    _seen[key] = now;
    onEvent(tipo, seq, uptime);
  }

  Future<void> stop() async {
    _running = false;
    await _valSub?.cancel();
    _valSub = null;
    await _connSub?.cancel();
    _connSub = null;
    try {
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
    onStatus('desligado');
  }

  /// Esquece o botao salvo (a proxima conexao faz um novo scan).
  Future<void> forget() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_prefKey);
  }
}
