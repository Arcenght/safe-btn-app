import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';

import 'ble_link.dart';

/// Tempo para o toque virar LONGO (igual ao firmware do botao).
const int kLongPressMs = 5000;

void main() => runApp(const SafeBtnApp());

class SafeBtnApp extends StatelessWidget {
  const SafeBtnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SafeBtn',
      theme: ThemeData(
        colorSchemeSeed: Colors.red,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

/// Fala com o backend (server.py).
class Api {
  Api(this.baseUrl, this.token);

  final String baseUrl;
  final String token;

  Uri _uri(String path) =>
      Uri.parse('${baseUrl.replaceAll(RegExp(r"/+$"), "")}$path');

  Map<String, String> get _headers =>
      {'Content-Type': 'application/json', 'X-Token': token};

  /// Retorna o "status" que o backend respondeu (iniciado, escalada_grave...).
  Future<String> sendEvent({
    required int tipo,
    required int seq,
    required int uptimeS,
    double? lat,
    double? lon,
  }) async {
    final body = <String, Object>{
      'tipo': tipo,
      'seq': seq,
      'uptime_s': uptimeS,
    };
    if (lat != null && lon != null) {
      body['lat'] = lat;
      body['lon'] = lon;
    }
    final r = await http
        .post(_uri('/evento'), headers: _headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw 'HTTP ${r.statusCode}';
    }
    final data = jsonDecode(r.body);
    return (data is Map ? data['status'] : null)?.toString() ?? 'ok';
  }

  Future<void> sendLocation(double lat, double lon) async {
    final r = await http
        .post(_uri('/localizacao'),
            headers: _headers, body: jsonEncode({'lat': lat, 'lon': lon}))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw 'HTTP ${r.statusCode}';
    }
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _url = '';
  String _token = '';
  final List<String> _logs = [];
  final Stopwatch _clock = Stopwatch()..start(); // faz o papel do uptime do botao
  int _seq = 0;

  // estado do "aperto" na tela
  bool _holding = false;
  bool _longFired = false;
  bool _warned = false;
  double _progress = 0;
  DateTime? _holdStart;
  Timer? _ticker;

  // botao fisico (BLE)
  late final BleLink _ble;
  bool _bleOn = false;
  bool _bleAutostarted = false;
  String _bleStatus = 'desligado';

  @override
  void initState() {
    super.initState();
    _ble = BleLink(
      onLog: _log,
      onStatus: (s) {
        if (mounted) setState(() => _bleStatus = s);
      },
      onEvent: _onButtonEvent,
    );
    _loadSettings();
    _ensureLocationPermission();
  }

  @override
  void dispose() {
    _ble.stop();
    _ticker?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------ util
  void _log(String line) {
    if (!mounted) return;
    final t = TimeOfDay.now();
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    setState(() {
      _logs.insert(0, '$hh:$mm  $line');
      if (_logs.length > 40) _logs.removeLast();
    });
  }

  /// Vibra o celular. pattern = [espera, vibra, espera, vibra, ...] em ms.
  Future<void> _buzz(List<int> pattern) async {
    try {
      final has = await Vibration.hasVibrator();
      if (has == true) {
        Vibration.vibrate(pattern: pattern);
      } else {
        HapticFeedback.heavyImpact();
      }
    } catch (_) {
      HapticFeedback.heavyImpact();
    }
  }

  // ------------------------------------------------------------ config
  Future<void> _loadSettings() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _url = p.getString('url') ?? '';
      _token = p.getString('token') ?? '';
      _bleOn = p.getBool('ble_on') ?? false;
    });
    if (_bleOn && !_bleAutostarted) {
      _bleAutostarted = true;
      _ble.start();
    }
  }

  Future<void> _toggleBle(bool on) async {
    setState(() => _bleOn = on);
    final p = await SharedPreferences.getInstance();
    await p.setBool('ble_on', on);
    if (on) {
      _ble.start();
    } else {
      await _ble.stop();
    }
  }

  Future<void> _rescan() async {
    await _ble.stop();
    await _ble.forget();
    _log('procurando o botão de novo');
    _ble.start();
  }

  /// Evento vindo do botao fisico (ja decodificado e sem duplicados).
  void _onButtonEvent(int tipo, int seq, int uptimeS) {
    if (tipo != 1 && tipo != 2) {
      _log('BOTÃO: tipo desconhecido ($tipo), ignorado');
      return;
    }
    _log('BOTÃO: ${tipo == 1 ? "TOQUE" : "LONGO"} (seq $seq)');
    _buzz([0, 60]); // o botao nao tem feedback: o celular confirma o recebimento
    _sendEvent(tipo, seq: seq, uptimeS: uptimeS);
  }

  Future<void> _openSettings() async {
    final u = TextEditingController(text: _url);
    final t = TextEditingController(text: _token);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Backend'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: u,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Endereço',
                hintText: 'http://192.168.0.10:8000',
              ),
            ),
            TextField(
              controller: t,
              decoration: const InputDecoration(labelText: 'Token do botão'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Salvar')),
        ],
      ),
    );
    if (ok == true) {
      final p = await SharedPreferences.getInstance();
      await p.setString('url', u.text.trim());
      await p.setString('token', t.text.trim());
      await _loadSettings();
      _log('configuração salva');
    }
  }

  // ------------------------------------------------------------ localizacao
  Future<void> _ensureLocationPermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _log('GPS desligado no celular');
        return;
      }
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) {
        p = await Geolocator.requestPermission();
      }
      if (p == LocationPermission.denied ||
          p == LocationPermission.deniedForever) {
        _log('permissão de localização negada');
      }
    } catch (e) {
      _log('erro ao pedir permissão de localização: $e');
    }
  }

  /// Pega a posicao atual (pode demorar) e manda ao backend depois do alerta.
  Future<void> _refreshLocation(Api api) async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );
      await api.sendLocation(pos.latitude, pos.longitude);
      _log('localização enviada '
          '(${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)})');
    } catch (e) {
      _log('sem localização ($e)');
    }
  }

  // ------------------------------------------------------------ envio
  /// tipo 1 = TOQUE, tipo 2 = LONGO (mesmos valores do firmware).
  Future<void> _sendEvent(int tipo, {int? seq, int? uptimeS}) async {
    final nome = tipo == 1 ? 'TOQUE' : 'LONGO';
    if (_url.isEmpty) {
      _log('configure o endereço do backend (engrenagem)');
      _buzz([0, 600]);
      return;
    }
    final useSeq = seq ?? _seq;
    if (seq == null) _seq = (_seq + 1) % 256;
    final api = Api(_url, _token);

    // Alerta sai NA HORA, com a ultima posicao conhecida se ja existir.
    // A posicao fresca vai logo depois, sem atrasar o alerta.
    Position? quick;
    try {
      quick = await Geolocator.getLastKnownPosition();
    } catch (_) {}

    _log('$nome: enviando...');
    try {
      final status = await api.sendEvent(
        tipo: tipo,
        seq: useSeq,
        uptimeS: uptimeS ?? _clock.elapsed.inSeconds,
        lat: quick?.latitude,
        lon: quick?.longitude,
      );
      _log('$nome: backend respondeu "$status"');
      _buzz([0, 120, 80, 120]); // dois toques curtos = enviado
    } catch (e) {
      _log('$nome: FALHOU ($e)');
      _buzz([0, 700]); // vibracao longa = falhou
    }
    unawaited(_refreshLocation(api));
  }

  // ------------------------------------------------------------ botao na tela
  void _onDown(PointerDownEvent _) {
    if (_holding) return;
    _holding = true;
    _longFired = false;
    _warned = false;
    _holdStart = DateTime.now();
    _sendEvent(1); // toque sai imediatamente, como no firmware
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 50), (_) {
      final ms = DateTime.now().difference(_holdStart!).inMilliseconds;
      setState(() => _progress = (ms / kLongPressMs).clamp(0.0, 1.0));
      if (!_warned && ms >= 3000) {
        _warned = true;
        _buzz([0, 80]); // aviso: falta pouco para o longo
      }
      if (!_longFired && ms >= kLongPressMs) {
        _longFired = true;
        _buzz([0, 400]);
        _sendEvent(2);
      }
    });
    setState(() {});
  }

  void _onUp(PointerEvent _) {
    _ticker?.cancel();
    _holding = false;
    setState(() => _progress = 0);
  }

  // ------------------------------------------------------------ tela
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SafeBtn'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 16),
            Text(
              _url.isEmpty ? 'Backend não configurado (engrenagem)' : _url,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.bluetooth),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Botão: $_bleStatus',
                        style: Theme.of(context).textTheme.bodyMedium),
                  ),
                  if (_bleOn)
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Procurar de novo',
                      onPressed: _rescan,
                    ),
                  Switch(value: _bleOn, onChanged: _toggleBle),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _onDown,
              onPointerUp: _onUp,
              onPointerCancel: _onUp,
              child: SizedBox(
                width: 220,
                height: 220,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox.expand(
                      child: CircularProgressIndicator(
                        value: _progress,
                        strokeWidth: 10,
                      ),
                    ),
                    Container(
                      width: 180,
                      height: 180,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _holding ? Colors.red.shade900 : Colors.red,
                      ),
                      child: const Center(
                        child: Text(
                          'TOQUE',
                          style: TextStyle(
                              fontSize: 28, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text('Segure 5 s para o alerta LONGO'),
            const SizedBox(height: 12),
            const Divider(),
            Expanded(
              child: ListView.builder(
                itemCount: _logs.length,
                itemBuilder: (_, i) => Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
                  child: Text(_logs[i],
                      style: Theme.of(context).textTheme.bodyMedium),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
