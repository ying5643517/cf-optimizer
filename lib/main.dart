import 'dart:io';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '反代优选',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class IpNode {
  String ip;
  int port;
  String region;
  int? latency; // ms
  double? speed; // Mbps

  IpNode({
    required this.ip,
    required this.port,
    required this.region,
    this.latency,
    this.speed,
  });
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _urlController = TextEditingController(
    text: 'https://fenlei.yangmt.de5.net/',
  );

  List<IpNode> _nodes = [];
  bool _isLoading = false;
  bool _isTesting = false;
  String _status = '就绪';

  final List<int> _availablePorts = [443, 2053, 2083, 2087, 2096, 8443];
  int _selectedPort = 443;

  // 从 Worker 获取数据
  Future<void> _fetchData() async {
    setState(() {
      _isLoading = true;
      _status = '正在获取 IP 列表...';
      _nodes = [];
    });

    try {
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(_urlController.text.trim()));
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      client.close();

      final lines = text.split(RegExp(r'[\r\n]+')).where((l) => l.trim().isNotEmpty);
      final List<IpNode> parsed = [];

      final regExp = RegExp(r'^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}):(\d+)(?:#([A-Z]{2}))?');
      
      for (var line in lines) {
        final match = regExp.firstMatch(line.trim());
        if (match != null) {
          final ip = match.group(1)!;
          final port = int.parse(match.group(2)!);
          final region = (match.group(3) ?? '').toUpperCase();
          
          if (['US', 'JP', 'SG', 'TW'].contains(region) && port == _selectedPort) {
            parsed.add(IpNode(ip: ip, port: port, region: region));
          }
        }
      }

      // 去重并随机抽取 50 个
      final seen = <String>{};
      final unique = <IpNode>[];
      for (var node in parsed) {
        final key = '${node.ip}:${node.port}';
        if (!seen.contains(key)) {
          seen.add(key);
          unique.add(node);
        }
      }

      unique.shuffle(Random());
      final selected = unique.take(50).toList();

      setState(() {
        _nodes = selected;
        _status = '已获取 ${_nodes.length} 个节点';
      });
    } catch (e) {
      setState(() {
        _status = '获取失败: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  // 测延迟（TCP 握手）
  Future<void> _testLatency() async {
    if (_nodes.isEmpty) return;
    setState(() {
      _isTesting = true;
      _status = '正在测试延迟...';
    });

    final List<Future> futures = [];
    for (var node in _nodes) {
      futures.add(_pingNode(node));
    }

    await Future.wait(futures);

    // 按延迟排序
    _nodes.sort((a, b) {
      if (a.latency == null) return 1;
      if (b.latency == null) return -1;
      return a.latency!.compareTo(b.latency!);
    });

    setState(() {
      _isTesting = false;
      _status = '延迟测试完成';
    });
  }

  Future<void> _pingNode(IpNode node) async {
    final stopwatch = Stopwatch()..start();
    try {
      final socket = await Socket.connect(node.ip, node.port, timeout: const Duration(seconds: 3));
      socket.destroy();
      stopwatch.stop();
      setState(() {
        node.latency = stopwatch.elapsedMilliseconds;
      });
    } catch (e) {
      setState(() {
        node.latency = null; // 超时或失败
      });
    }
  }

  // 测速度（下载 10MB）
  Future<void> _testSpeed(IpNode node) async {
    setState(() {
      node.speed = -1; // 表示测速中
    });

    try {
      final stopwatch = Stopwatch()..start();
      final socket = await SecureSocket.connect(node.ip, node.port, timeout: const Duration(seconds: 5));
      
      socket.write('GET /__down?bytes=10000000 HTTP/1.1\r\n');
      socket.write('Host: speed.cloudflare.com\r\n');
      socket.write('Connection: close\r\n\r\n');

      int bytes = 0;
      await for (var data in socket) {
        bytes += data.length;
      }
      stopwatch.stop();

      final elapsedSeconds = stopwatch.elapsedMilliseconds / 1000.0;
      final mbps = (bytes * 8) / 1000000 / elapsedSeconds;

      setState(() {
        node.speed = mbps;
      });
    } catch (e) {
      setState(() {
        node.speed = 0; // 失败
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('反代优选 v1.0'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            // 输入框和按钮
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  children: [
                    TextField(
                      controller: _urlController,
                      decoration: const InputDecoration(
                        labelText: '数据源 Worker 地址',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text('端口: '),
                        const SizedBox(width: 8),
                        DropdownButton<int>(
                          value: _selectedPort,
                          items: _availablePorts.map((p) => DropdownMenuItem(value: p, child: Text(p.toString()))).toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setState(() {
                                _selectedPort = val;
                              });
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _isLoading ? null : _fetchData,
                            child: const Text('获取数据（随机50个）'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: (_nodes.isEmpty || _isTesting) ? null : _testLatency,
                            child: Text(_isTesting ? '测试中...' : '测试延迟'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(_status, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 8),
            // 列表
            Expanded(
              child: _nodes.isEmpty
                  ? const Center(child: Text('暂无数据，请先获取'))
                  : ListView.builder(
                      itemCount: _nodes.length,
                      itemBuilder: (context, index) {
                        final node = _nodes[index];
                        String latencyText = '待测';
                        Color latencyColor = Colors.grey;
                        if (node.latency != null) {
                          latencyText = '${node.latency} ms';
                          latencyColor = node.latency! < 200 ? Colors.green : (node.latency! < 500 ? Colors.orange : Colors.red);
                        } else if (node.latency == null && _isTesting) {
                          latencyText = '超时';
                        }

                        String speedText = '';
                        if (node.speed == -1) speedText = '测速中...';
                        else if (node.speed != null && node.speed! > 0) speedText = '${node.speed!.toStringAsFixed(1)} Mbps';
                        else if (node.speed == 0) speedText = '失败';

                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          child: ListTile(
                            title: Text('${node.ip}:${node.port} #${node.region}'),
                            subtitle: Row(
                              children: [
                                Text(latencyText, style: TextStyle(color: latencyColor, fontWeight: FontWeight.bold)),
                                const SizedBox(width: 12),
                                Text(speedText, style: const TextStyle(color: Colors.blue)),
                              ],
                            ),
                            trailing: ElevatedButton(
                              onPressed: () => _testSpeed(node),
                              child: const Text('测速'),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
