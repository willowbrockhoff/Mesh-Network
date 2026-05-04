import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'offline_map_page.dart';
import 'dart:convert';

// Shared BLE instance for entire app. FlutterReactiveBle manages scanning, connecting, GATT opperations.
final ble = FlutterReactiveBle();

// Custom UUIDs I set in ESP32 NodeCode.
final Uuid serviceUuid = Uuid.parse(
  "12345678-1234-5678-1234-56789abcdef0",
); //Service UUID exposed by ESP32
final Uuid batCharUuid = Uuid.parse(
  "12345678-1234-5678-1234-56789abcdef1",
); // Characteristic UUID that represents battery notifs/reads
final Uuid gpsCharUuid = Uuid.parse(
  "12345678-1234-5678-1234-56789abcdef2",
); // Characteristic UUID that represents GPS notifs/reads
final Uuid modeCharUuid = Uuid.parse(
  "12345678-1234-5678-1234-56789abcdef3",
); // Characteristic UUID that represents Node's Mode

// Define what is consider a “MeshNode” during scanning
// Nodes are advertising their name, so I'm using name matching
bool looksLikeMeshNode(DiscoveredDevice d) {
  final n = d.name.toLowerCase();
  return n.contains("wildermesh"); // All nodes are named "MeshNode-##"
}

// Produce display name for a DiscoveredDevice
String displayName(DiscoveredDevice d) {
  final name = d.name.trim();
  if (name.isNotEmpty) return name;
  // Fall back to device.ID as device.name can sometimes be empty on Andriod
  return "MeshNode (${d.id})";
}

// Model for a connected node in UI list
// Contains: static ID fileds (deviceID, name), dynamic state (batteryText, connState), stream subs that MUST be cancelled on disconnect/remove
class NodeEntry {
  final String deviceId;
  final String name;

  // Display battery and GPS value as text, updated by notifs/reads
  String batteryText = "--";
  String gpsText = "--";
  String modeText = "--";

  double? latitude;
  double? longitude;
  // Current conection state as reported by FlutterReactiveBle
  DeviceConnectionState connState = DeviceConnectionState.disconnected;

  // Sub to connection stream for device
  StreamSubscription<ConnectionStateUpdate>? connSub;
  //Sub to characteristic notfi stream
  StreamSubscription<List<int>>? notifySub;
  StreamSubscription<List<int>>? gpsNotifySub;
  StreamSubscription<List<int>>? modeNotifySub;

  NodeEntry({required this.deviceId, required this.name});
}

void main() {
  runApp(const MeshNodeApp());
}

class MeshNodeApp extends StatelessWidget {
  const MeshNodeApp({super.key});
  //Establishing theme to pull from
  static const Color forest = Color(0xFF1F4D3A);
  static const Color sage = Color(0xFF6E8B74);
  static const Color teal = Color(0xFF2E6F77);
  static const Color cream = Color(0xFFF4F1E8);
  static const Color mist = Color(0xFFE6EFE8);
  static const Color sand = Color(0xFFE9E3D6);
  static const Color border = Color(0xFFD3DDD4);

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: forest,
      brightness: Brightness.light,
      primary: forest,
      secondary: teal,
      surface: cream,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: cream,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
          foregroundColor: forest,
          titleTextStyle: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: forest,
            letterSpacing: 0.2,
          ),
        ),
        cardTheme: CardThemeData(
          color: Colors.white.withAlpha(225),
          elevation: 2,
          shadowColor: Colors.black12,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: const BorderSide(color: border),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: forest,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: teal,
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: cream,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
        ),
        dividerTheme: const DividerThemeData(color: border, thickness: 1),
      ),
      home: const ConnectionScreen(),
    );
  }
}

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});
  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  // All nodes the user is connected to
  final List<NodeEntry> _nodes = [];
  //Active scan sub (is NULL when not scanning)
  StreamSubscription<DiscoveredDevice>? _scanSub;
  // During scanning "MeshNode"-esque devices are stored here by deviceID
  // Purpose: avoid duplicates and keep best RSSI seen
  final Map<String, DiscoveredDevice> _scanCandidates = {};
  // Timer used to stop scanning after 5s
  Timer? _scanTimer;

  String _status = "Idle"; // Default. Displayed at top of app
  bool _isScanning = false;
  //Continuing theme
  static const Color forest = MeshNodeApp.forest;
  static const Color sage = MeshNodeApp.sage;
  static const Color teal = MeshNodeApp.teal;
  static const Color cream = MeshNodeApp.cream;
  static const Color mist = MeshNodeApp.mist;
  static const Color sand = MeshNodeApp.sand;
  static const Color border = MeshNodeApp.border;

  @override
  void initState() {
    super.initState();
    // Wait until app renders to request premissions for BLE scanning/connecting on Andriod
    // Avoids context issue and keep init quick
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initPermissions();
    });
  }

  // Set the nodes mode in-app
  Future<void> _setNodeMode(NodeEntry n, String mode) async {
    // Cannot change mode when node is disconnected
    if (n.connState != DeviceConnectionState.connected) {
      setState(() => _status = "Connect to ${n.name} before changing mode");
      return;
    }
    // Get node's info
    final modeQc = QualifiedCharacteristic(
      deviceId: n.deviceId,
      serviceId: serviceUuid,
      characteristicId: modeCharUuid,
    );

    try {
      await ble.writeCharacteristicWithResponse(
        modeQc,
        value: utf8.encode(mode),
      );

      setState(() {
        n.modeText = mode;
        _status = "Set ${n.name} mode to $mode";
      });
    } catch (e) {
      setState(() => _status = "Mode write failed on ${n.name}: $e");
    }
  }

  void _updateNodeGpsFromText(NodeEntry entry, String text) {
    entry.gpsText = text.trim();

    final parts = entry.gpsText.split(',');
    if (parts.length != 2) {
      entry.latitude = null;
      entry.longitude = null;
      return;
    }

    final lat = double.tryParse(parts[0].trim());
    final lng = double.tryParse(parts[1].trim());

    if (lat == null || lng == null) {
      entry.latitude = null;
      entry.longitude = null;
      return;
    }

    entry.latitude = lat;
    entry.longitude = lng;
  }

  // Req runtime premission for BLE scanning/connecting on Andriod
  // IOS to come (hopefully)
  Future<void> _initPermissions() async {
    if (!Platform.isAndroid) return;

    // Andriod premissions:
    final results = await [
      Permission.bluetoothScan, // Needed to scan
      Permission.bluetoothConnect, // Needed to connect
      Permission.locationWhenInUse, // Needed for BLE scanning sometimes?
    ].request();
    // If premissions denied, show in status
    final denied = results.entries.where((e) => !e.value.isGranted).toList();
    if (denied.isNotEmpty) {
      setState(() {
        _status = "Permissions denied: ${denied.map((e) => e.key).join(", ")}";
      });
    }
  }

  // returns a label for picker list (name & ID) (Sometimes BLE names are empty)
  String candidateLabel(DiscoveredDevice d) {
    final name = d.name.trim();
    if (name.isNotEmpty) return "$name  (${d.id})";
    return d.id; // Fallback if name is empty
  }

  // Check if device is already in list to prevent duplicates
  bool _alreadyAdded(String deviceId) {
    return _nodes.any((n) => n.deviceId == deviceId);
  }

  // Stop scanning and show picker pop-up for device choice.
  // Called when (1) timer expires or (2) user presses "Stop scanning" during scan
  Future<void> _stopScanAndShowPicker() async {
    // Stop scan stream & timer
    await _scanSub?.cancel();
    _scanTimer?.cancel();
    //Update UI
    setState(() {
      _isScanning = false;
      _status = "Scan complete. Found ${_scanCandidates.length} candidate(s).";
    });
    // if scan finds nothing, exit
    if (_scanCandidates.isEmpty) {
      return;
    }

    // Convert map to list and sort devices by RSSI descending (strongest to weakest signal)
    final candidates = _scanCandidates.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    // Show dialog listing all candidates, returns selected device when pressed
    final chosen = await showDialog<DiscoveredDevice>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text("Select a node"),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: candidates.length,
              separatorBuilder: (_, __) => const Divider(height: 16),
              itemBuilder: (_, i) {
                final d = candidates[i];
                return ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  leading: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: mist,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.hub_outlined, color: forest),
                  ),
                  // Prefer name if avaliable, else show "Unnamed"
                  title: Text(
                    d.name.isNotEmpty ? d.name : "Unnamed",
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  // Show ID and RSSI
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text("ID: ${d.id}\nRSSI: ${d.rssi}"),
                  ),
                  isThreeLine: true,
                  // Selecting returns device info in pop-up
                  onTap: () => Navigator.pop(ctx, d),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text("Cancel"),
            ),
          ],
        );
      },
    );
    // If user cancels, update status and stop
    if (chosen == null) {
      setState(() => _status = "No node selected");
      return;
    }
    // Asks for confirmation before connecting to device (device info pop-up)
    final ok = await _confirmConnectDialog(chosen);
    if (!ok) {
      setState(() => _status = "User declined connection");
      return;
    }
    // Connect and add node to UI list
    _connectAndAddNode(chosen);
  }

  // Scan for "MeshNode" devices for 5s. Collect candidates then show picker for selection
  Future<void> _scanForMeshNode() async {
    // If already scanning, stop and show whatever is found so far
    if (_isScanning) {
      await _stopScanAndShowPicker();
      return;
    }

    // Ensure previous scan/timer are cancelled and clear candidates for next scan
    await _scanSub?.cancel();
    _scanTimer?.cancel();
    _scanCandidates.clear();

    // Update UI before scanning
    setState(() {
      _isScanning = true;
      _status = "Scanning for nearby nodes (5s)...";
    });

    // Begin scanning:
    // withServices empty: no service filter so we don't see all advertising noise (it's a lot)
    // scanMode LowLatency: quick results but power hungry when on. Will change for low power state eventually
    _scanSub = ble
        .scanForDevices(withServices: const [], scanMode: ScanMode.lowLatency)
        .listen(
          (d) {
            // Only keep devices that looksLike WilderMesh Node-## by name
            final isMesh = d.name.toLowerCase().contains("wildermesh");
            if (!isMesh) return;

            // Skip nodes already in UI list
            if (_alreadyAdded(d.id)) return;

            // Keep strongest RSSI seen for deviceID
            final existing = _scanCandidates[d.id];
            if (existing == null || d.rssi > existing.rssi) {
              _scanCandidates[d.id] = d;
            }
          },
          onError: (e) async {
            // If scanning errors, stop scan/timer and update status
            await _scanSub?.cancel();
            _scanTimer?.cancel();
            setState(() {
              _isScanning = false;
              _status = "Scan error: $e";
            });
          },
        );

    // After 5 seconds, stop scan and show picker
    _scanTimer = Timer(const Duration(seconds: 5), () async {
      await _stopScanAndShowPicker();
    });
  }

  // Show confirmation dialog before connecting to selected device
  Future<bool> _confirmConnectDialog(DiscoveredDevice d) async {
    final name = displayName(d);
    final id = d.id;
    // showDialog returns feture<T?> so merge NULL->false
    return (await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text("Connect?"),
            content: Text("Do you want to connect to this node?\n\n$name\n$id"),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text("No"),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: forest,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text("Yes"),
              ),
            ],
          ),
        )) ??
        false;
  }

  // Create NodeEntry and initiate BLE connection then discover serices.
  // read battery once, sub to battery notifs
  void _connectAndAddNode(DiscoveredDevice d) {
    // Prevent duplicates
    final already = _nodes.any((n) => n.deviceId == d.id);
    if (already) {
      setState(() => _status = "Already connected/added: ${d.id}");
      return;
    }
    // Create entry & add to UI list
    final entry = NodeEntry(deviceId: d.id, name: displayName(d));
    setState(() {
      _nodes.add(entry);
      _status = "Connecting to ${entry.name}...";
    });

    // Start connection stream. Emits updates as connection state
    // connectionTimeout: time we will wait before failing attempt
    entry.connSub = ble
        .connectToDevice(
          id: entry.deviceId,
          connectionTimeout: const Duration(seconds: 12),
        )
        .listen(
          (update) async {
            // Update connection state on the NodeEntry
            entry.connState = update.connectionState;
            // If connected, do service discovery & setup notifs/reads
            if (update.connectionState == DeviceConnectionState.connected) {
              setState(
                () => _status = "Connected: ${entry.name}. Discovering...",
              );

              try {
                // Discover all services/characteristics
                await ble.discoverAllServices(entry.deviceId);
                // Read discovered service list
                final services = await ble.getDiscoveredServices(
                  entry.deviceId,
                );
                // Verify UUID match
                final hasService = services.any((s) => s.id == serviceUuid);
                if (!hasService) {
                  setState(
                    () => _status =
                        "Connected, but service not found on ${entry.name} (UUID mismatch?)",
                  );
                  return;
                }
                // Build QualifiedCharacteristic to identify deviceID, service/char UUID
                final qc = QualifiedCharacteristic(
                  deviceId: entry.deviceId,
                  serviceId: serviceUuid,
                  characteristicId: batCharUuid,
                );
                // Do the same for GPS chars
                final gpsQc = QualifiedCharacteristic(
                  deviceId: entry.deviceId,
                  serviceId: serviceUuid,
                  characteristicId: gpsCharUuid,
                );

                final modeQc = QualifiedCharacteristic(
                  deviceId: entry.deviceId,
                  serviceId: serviceUuid,
                  characteristicId: modeCharUuid,
                );

                // Read battery char immediately once (best effort)
                try {
                  final value = await ble.readCharacteristic(qc);
                  entry.batteryText = _bytesToText(value);
                } catch (e) {
                  // If read fails show error in UI
                  entry.batteryText = "read err";
                }
                // read GPS once
                /*try {
            final value = await ble.readCharacteristic(gpsQc);
            entry.gpsText = _bytesToText(value);
          } catch (e) {
            // If read fails show error in UI
            entry.gpsText = "read err";
          }*/
                try {
                  final value = await ble.readCharacteristic(gpsQc);
                  _updateNodeGpsFromText(entry, _bytesToText(value));
                } catch (e) {
                  entry.gpsText = "read err";
                  entry.latitude = null;
                  entry.longitude = null;
                }

                try {
                  final value = await ble.readCharacteristic(modeQc);
                  entry.modeText = _bytesToText(value);
                } catch (e) {
                  entry.modeText = "read err";
                }
                setState(() {});

                // Subscribe to notifications to update UI when ESP32 sends change
                await entry.notifySub?.cancel();
                entry.notifySub = ble
                    .subscribeToCharacteristic(qc)
                    .listen(
                      (data) {
                        // Convert raw bytes to txt and store
                        entry.batteryText = _bytesToText(data);
                        setState(() {}); // Ppdate list
                      },
                      onError: (e) {
                        setState(
                          () => _status = "Notify error on ${entry.name}: $e",
                        );
                      },
                    );
                // Subscribe to GPS to update UI when ESP32 sends change
                await entry.gpsNotifySub?.cancel();
                entry.gpsNotifySub = ble
                    .subscribeToCharacteristic(gpsQc)
                    .listen(
                      (data) {
                        // Convert raw bytes to txt and store
                        //entry.gpsText = _bytesToText(data);
                        _updateNodeGpsFromText(entry, _bytesToText(data));
                        setState(() {}); // Ppdate list
                      },
                      onError: (e) {
                        setState(
                          () =>
                              _status = "GPS Notify error on ${entry.name}: $e",
                        );
                      },
                    );
                await entry.modeNotifySub?.cancel();
                entry.modeNotifySub = ble
                    .subscribeToCharacteristic(modeQc)
                    .listen(
                      (data) {
                        entry.modeText = _bytesToText(data);
                        setState(() {}); // Ppdate list
                      },
                      onError: (e) {
                        setState(
                          () => _status =
                              "Mode Notify error on ${entry.name}: $e",
                        );
                      },
                    );

                setState(
                  () => _status = "Receiving battery from ${entry.name}...",
                );
              } catch (e) {
                setState(() => _status = "Discover error on ${entry.name}: $e");
              }
            }
            // if disconnected: cancel notifs and update streams
            if (update.connectionState == DeviceConnectionState.disconnected) {
              await entry.notifySub?.cancel();
              await entry.gpsNotifySub?.cancel();
              await entry.modeNotifySub?.cancel();
              setState(() => _status = "Disconnected: ${entry.name}");
            }
            // Force UI refresh for connection st updates
            setState(() {});
          },
          onError: (e) {
            setState(() => _status = "Connect error on ${entry.name}: $e");
          },
        );
  }

  // Reconnect and existing NodeEntry using deviceID
  // Resuses inital connect but doesnt re-add to UI list
  void _reconnect(NodeEntry n) {
    // If already connected/connecting, don't start another stream
    if (n.connState == DeviceConnectionState.connected ||
        n.connState == DeviceConnectionState.connecting) {
      setState(() => _status = "Already connecting/connected: ${n.name}");
      return;
    }

    setState(() => _status = "Reconnecting to ${n.name}...");

    // Cancel old connection sub before starting new sub
    n.connSub?.cancel();
    // Start connection stream again
    n.connSub = ble
        .connectToDevice(
          id: n.deviceId,
          connectionTimeout: const Duration(seconds: 12),
        )
        .listen(
          (update) async {
            n.connState = update.connectionState;
            // When connected, set up notifs/reads
            if (update.connectionState == DeviceConnectionState.connected) {
              setState(() => _status = "Connected: ${n.name}. Discovering...");
              await _setupBatteryNotifications(n); // defined below
            }
            // On disconnect, stop notis to prevent leaks
            if (update.connectionState == DeviceConnectionState.disconnected) {
              await n.notifySub?.cancel();
              setState(() => _status = "Disconnected: ${n.name}");
            }

            setState(() {});
          },
          onError: (e) {
            setState(() => _status = "Reconnect error on ${n.name}: $e");
          },
        );
  }

  // remove node from UI list and stop streams
  Future<void> _removeNode(NodeEntry n) async {
    // Cancel char notif/connection streams
    await n.notifySub?.cancel();
    await n.gpsNotifySub?.cancel();
    await n.modeNotifySub?.cancel();
    await n.connSub?.cancel();
    // remove from list & update status
    setState(() {
      _nodes.removeWhere((x) => x.deviceId == n.deviceId);
      _status = "Removed: ${n.name}";
    });
  }

  // Convert characteristic byte to string
  String _bytesToText(List<int> data) {
    return String.fromCharCodes(data).trim();
  }

  // Disconnect node by cancelling subs. FlutterReactiveBle drops connection when conn stream is cancelled.
  Future<void> _disconnect(NodeEntry n) async {
    await n.notifySub?.cancel();
    await n.gpsNotifySub?.cancel();
    await n.modeNotifySub?.cancel();
    await n.connSub?.cancel();
    setState(() {
      n.connState = DeviceConnectionState.disconnected;
      // Keep last battery reading
      _status = "Disconnected: ${n.name}";
    });
  }

  // Shared helper for discovery services, verfying UUID, read battery once, & sub notifs for existing NodeEntry
  Future<void> _setupBatteryNotifications(NodeEntry n) async {
    try {
      // Discover all services/chars for device
      await ble.discoverAllServices(n.deviceId);
      final services = await ble.getDiscoveredServices(n.deviceId);
      // Verify expected service exists
      final hasService = services.any((s) => s.id == serviceUuid);
      if (!hasService) {
        setState(
          () => _status = "Service not found on ${n.name} (UUID mismatch?)",
        );
        return;
      }
      // Create qualified char reference
      final qc = QualifiedCharacteristic(
        deviceId: n.deviceId,
        serviceId: serviceUuid,
        characteristicId: batCharUuid,
      );

      // Read once (best effort)
      try {
        final value = await ble.readCharacteristic(qc);
        n.batteryText = _bytesToText(value);
      } catch (_) {
        n.batteryText = "read err";
      }

      // Sub for continuous updates
      await n.notifySub?.cancel();
      n.notifySub = ble
          .subscribeToCharacteristic(qc)
          .listen(
            (data) {
              n.batteryText = _bytesToText(data);
              setState(() {});
            },
            onError: (e) {
              setState(() => _status = "Notify error on ${n.name}: $e");
            },
          );

      setState(() => _status = "Receiving battery from ${n.name}...");
    } catch (e) {
      setState(() => _status = "Discover/read error on ${n.name}: $e");
    }
  }

  @override
  void dispose() {
    // Cancel streams/timers to prevent leaks/BLE activity
    _scanSub?.cancel();
    // Cancel per-node subs
    for (final n in _nodes) {
      n.notifySub?.cancel();
      n.connSub?.cancel();
      n.modeNotifySub?.cancel();
      n.gpsNotifySub?.cancel();
    }
    super.dispose();
  }

  // Status bar indicates most recent notible action with app and nodes
  @override
  Widget _buildStatusCard() {
    final Color dotColor = _isScanning ? teal : forest;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 14,
              height: 14,
              margin: const EdgeInsets.only(top: 4),
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: dotColor.withAlpha(70),
                    blurRadius: 10,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "System Status",
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: forest,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _status,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      height: 1.35,
                      color: Colors.black87,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Button to begin scanning for nearby nodes
  Widget _buildScanButton() {
    final scanBtnText = _isScanning
        ? "Stop scanning"
        : "Scan for WilderMesh Node";

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _scanForMeshNode,
        icon: Icon(_isScanning ? Icons.stop_circle_outlined : Icons.radar),
        label: Text(scanBtnText),
      ),
    );
  }

  // Offline map to view nodes by GPS coordinates
  Widget _buildMapCard() {
    final mapPins = _nodes
        .where((n) => n.latitude != null && n.longitude != null)
        .map(
          (n) => MapPinData(
            id: n.deviceId,
            label: n.name,
            latitude: n.latitude!,
            longitude: n.longitude!,
          ),
        )
        .toList();

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: mist,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.public_outlined, color: forest),
                ),
                const SizedBox(width: 10),
                Text(
                  "Map",
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: forest,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            AspectRatio(
              aspectRatio: 1.05,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: border),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: OfflineMapView(pins: mapPins),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader() {
    return Row(
      children: [
        Text(
          "Connected Nodes",
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            color: forest,
          ),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: sand,
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: border),
          ),
          child: Text(
            "${_nodes.length}",
            style: const TextStyle(fontWeight: FontWeight.w800, color: forest),
          ),
        ),
      ],
    );
  }

  Widget _stateChip(NodeEntry n) {
    final String text = n.connState.name;
    Color bg;
    Color fg;

    switch (n.connState) {
      case DeviceConnectionState.connected:
        bg = const Color(0xFFDDEDDD);
        fg = const Color(0xFF28533B);
        break;
      case DeviceConnectionState.connecting:
        bg = const Color(0xFFD9EBF0);
        fg = const Color(0xFF235E66);
        break;
      case DeviceConnectionState.disconnecting:
        bg = const Color(0xFFEFE4D7);
        fg = const Color(0xFF785B2C);
        break;
      case DeviceConnectionState.disconnected:
        bg = const Color(0xFFE7E2DB);
        fg = const Color(0xFF6B6257);
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }

  Widget _infoChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: mist,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: teal),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: forest,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNodeCard(NodeEntry n) {

    final connected = n.connState == DeviceConnectionState.connected;
    final connecting = n.connState == DeviceConnectionState.connecting;
    final isSos = n.modeText.trim().toUpperCase() == "SOS";

    // Change color based on node's conection state + red in SOS mde
    Color glow = isSos
        ? const Color(0xFFB3261E)
        : connected
        ? const Color(0xFF4F8A67)
        : connecting
        ? teal
        : const Color(0xFF8A8A8A);

    return Card(
      // bright red if in SOS mode
      color: isSos ? const Color(0xFFFFE1E1) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(
          color: isSos ? const Color(0xFFB3261E) : border,
          width: isSos ? 2 : 1,
        ),
      ),
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: glow,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: glow.withAlpha(80),
                        blurRadius: 10,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    n.name,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: forest,
                    ),
                  ),
                ),
                _stateChip(n),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              "ID: ${n.deviceId}",
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.black54,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _infoChip(
                  Icons.battery_6_bar_outlined,
                  "Battery ${n.batteryText} V",
                ),
                _infoChip(Icons.route_outlined, "Mode ${n.modeText}"),
                _infoChip(Icons.location_on_outlined, "GPS ${n.gpsText}"),
              ],
            ),
            const SizedBox(height: 14),
            if (connected) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () => _setNodeMode(n, "NORMAL"),
                    icon: const Icon(Icons.power_settings_new),
                    label: const Text("Normal"),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => _setNodeMode(n, "LOW_POWER"),
                    icon: const Icon(Icons.battery_saver_outlined),
                    label: const Text("Low Power"),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => _setNodeMode(n, "SOS"),
                    icon: const Icon(Icons.sos_outlined),
                    label: const Text("SOS"),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                if (connected)
                  TextButton.icon(
                    onPressed: () => _disconnect(n),
                    icon: const Icon(Icons.link_off),
                    label: const Text("Disconnect"),
                  )
                else ...[
                  TextButton.icon(
                    onPressed: connecting ? null : () => _reconnect(n),
                    icon: const Icon(Icons.refresh),
                    label: const Text("Reconnect"),
                  ),
                  TextButton.icon(
                    onPressed: () => _removeNode(n),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text("Remove"),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
  // List to view connected nodes
  Widget _buildNodeList() {
    if (_nodes.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: mist,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(
                  Icons.device_hub_outlined,
                  color: forest,
                  size: 28,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                "No nodes added yet",
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: forest,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                "Scan to discover nearby WilderMesh Nodes.",
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: Colors.black54),
              ),
            ],
          ),
        ),
      );
    }
    return Column(children: _nodes.map(_buildNodeCard).toList());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFFF4F1E8),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: Padding(
          padding: const EdgeInsets.only(top: 10.0),
          child: Image.asset('assets/images/wildermesh_logo_3.png', height: 92),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFF4F1E8), Color(0xFFEAF1EB)],
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            children: [
              _buildStatusCard(),
              const SizedBox(height: 16),
              _buildScanButton(),
              const SizedBox(height: 16),
              _buildMapCard(),
              const SizedBox(height: 20),
              _buildSectionHeader(),
              const SizedBox(height: 12),
              _buildNodeList(),
            ],
          ),
        ),
      ),
    );
  }
}
