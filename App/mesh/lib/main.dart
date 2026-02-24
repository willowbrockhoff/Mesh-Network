import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

// Shared BLE instance for entire app. FlutterReactiveBle manages scanning, connecting, GATT opperations.
final ble = FlutterReactiveBle();

// Custom UUIDs I set in ESP32 NodeCode. 
final Uuid serviceUuid = Uuid.parse("12345678-1234-5678-1234-56789abcdef0"); //Service UUID exposed by ESP32
final Uuid batCharUuid = Uuid.parse("12345678-1234-5678-1234-56789abcdef1"); // Characteristic UUID that represents battery notifs/reads

// Define what is consider a “MeshNode” during scanning
// Nodes are advertising their name, so I'm using name matching
bool looksLikeMeshNode(DiscoveredDevice d){
  final n = d.name.toLowerCase();
  return n.contains("meshnode"); // All nodes are named "MeshNode-##"
}

// Produce display name for a DiscoveredDevice
String displayName(DiscoveredDevice d){
  final name = d.name.trim();
  if (name.isNotEmpty) return name;
  // Fall back to device.ID as device.name can sometimes be empty on Andriod
  return "MeshNode (${d.id})";
}

// Model for a connected node in UI list
// Contains: static ID fileds (deviceID, name), dynamic state (batteryText, connState), stream subs that MUST be cancelled on disconnect/remove
class NodeEntry{
  final String deviceId;
  final String name;

  // Display battery value as text, updated by notifs/reads
  String batteryText = "--";
  // Current conection state as reported by FlutterReactiveBle
  DeviceConnectionState connState = DeviceConnectionState.disconnected;
  
  // Sub to connection stream for device
  StreamSubscription<ConnectionStateUpdate>? connSub;
  //Sub to characteristic notfi stream
  StreamSubscription<List<int>>? notifySub;

  NodeEntry({required this.deviceId, required this.name});
}

void main() {
  // Minimal app for MVP. More to come
  // home is ConnectionScreen atm
  runApp(const MaterialApp(home: ConnectionScreen()));
}

class ConnectionScreen extends StatefulWidget{
  const ConnectionScreen({super.key});
  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen>{

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

  @override
  void initState() {
    super.initState();
    // Wait until app renders to request premissions for BLE scanning/connecting on Andriod
    // Purpose: avoid context issue and keep init quick
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initPermissions();
    });
  }

  // Req runtime premission for BLE scanning/connecting on Andriod
  // IOS to come (hopefully)
  Future<void> _initPermissions() async{
    if (!Platform.isAndroid) return;

    // Andriod premissions:
    final results = await [
      Permission.bluetoothScan,     // Needed to scan
      Permission.bluetoothConnect,  // Needed to connect
      Permission.locationWhenInUse, // Needed for BLE scanning sometimes?
    ].request();
     // If premissions denied, show in status
    final denied = results.entries.where((e) => !e.value.isGranted).toList();
    if (denied.isNotEmpty) {
      setState(() {
        _status =
            "Permissions denied: ${denied.map((e) => e.key).join(", ")}";
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
        title: const Text("Select a MeshNode"),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: candidates.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final d = candidates[i];
              return ListTile(
                // Prefer name if avaliable, else show "Unnamed"
                title: Text(d.name.isNotEmpty ? d.name : "Unnamed"),
                // Show ID and RSSI
                subtitle: Text("ID: ${d.id}\nRSSI: ${d.rssi}"),
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
    _status = "Scanning for MeshNode (5s)...";
  });

  // Begin scanning:
  // withServices empty: no service filter so we don't see all advertising noise (it's a lot)
  // scanMode LowLatency: quick results but power hungry when on. Will change for low power state eventually
  _scanSub = ble
      .scanForDevices(withServices: const [], scanMode: ScanMode.lowLatency)
      .listen((d) {
    // Only keep devices that looksLikeMeshNode by name
    final isMesh = d.name.toLowerCase().contains("meshnode");
    if (!isMesh) return;

    // Skip nodes already in UI list
    if (_alreadyAdded(d.id)) return;

    // Keep strongest RSSI seen for deviceID
    final existing = _scanCandidates[d.id];
    if (existing == null || d.rssi > existing.rssi) {
      _scanCandidates[d.id] = d;
    }
  }, onError: (e) async {
    // If scanning errors, stop scan/timer and update status
    await _scanSub?.cancel();
    _scanTimer?.cancel();
    setState(() {
      _isScanning = false;
      _status = "Scan error: $e";
    });
  });

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
              ElevatedButton(
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
        .connectToDevice(id: entry.deviceId, connectionTimeout: const Duration(seconds: 12))
        .listen((update) async {
      // Update connection state on the NodeEntry
      entry.connState = update.connectionState;
      // If connected, do service discovery & setup notifs/reads
      if (update.connectionState == DeviceConnectionState.connected) {
        setState(() => _status = "Connected: ${entry.name}. Discovering...");

        try {
          // Discover all services/characteristics
          await ble.discoverAllServices(entry.deviceId);
          // Read discovered service list
          final services = await ble.getDiscoveredServices(entry.deviceId);
          // Verify UUID match
          final hasService = services.any((s) => s.id == serviceUuid);
          if (!hasService) {
            setState(() => _status =
                "Connected, but service not found on ${entry.name} (UUID mismatch?)");
            return;
          }
          // Build QualifiedCharacteristic to identify deviceID, service/char UUID
          final qc = QualifiedCharacteristic(
            deviceId: entry.deviceId,
            serviceId: serviceUuid,
            characteristicId: batCharUuid,
          );

          // Read battery char immediately once (best effort)
          try {
            final value = await ble.readCharacteristic(qc);
            entry.batteryText = _bytesToText(value);
          } catch (e) {
            // If read fails show error in UI
            entry.batteryText = "read err";
          }
          setState(() {}); 

          // Subscribe to notifications to update UI when ESP32 sends change
          await entry.notifySub?.cancel();
          entry.notifySub = ble.subscribeToCharacteristic(qc).listen((data) {
            // Convert raw bytes to txt and store
            entry.batteryText = _bytesToText(data);
            setState(() {}); // Ppdate list
          }, onError: (e) {
            setState(() => _status = "Notify error on ${entry.name}: $e");
          });

          setState(() => _status = "Receiving battery from ${entry.name}...");
        } catch (e) {
          setState(() => _status = "Discover error on ${entry.name}: $e");
        }
      }
      // if disconnected: cancel notifs and update streams
      if (update.connectionState == DeviceConnectionState.disconnected) {
        await entry.notifySub?.cancel();
        setState(() => _status = "Disconnected: ${entry.name}");
      }
      // Force UI refresh for connection st updates
      setState(() {});
    }, onError: (e) {
      setState(() => _status = "Connect error on ${entry.name}: $e");
    });
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
        .connectToDevice(id: n.deviceId, connectionTimeout: const Duration(seconds: 12))
        .listen((update) async {
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
    }, onError: (e) {
      setState(() => _status = "Reconnect error on ${n.name}: $e");
    });
  }

// remove node from UI list and stop streams
Future<void> _removeNode(NodeEntry n) async {
    // Cancel char notif/connection streams
    await n.notifySub?.cancel();
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
        setState(() => _status = "Service not found on ${n.name} (UUID mismatch?)");
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
      n.notifySub = ble.subscribeToCharacteristic(qc).listen((data) {
        n.batteryText = _bytesToText(data);
        setState(() {});
      }, onError: (e) {
        setState(() => _status = "Notify error on ${n.name}: $e");
      });

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
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Button label reflects scanning state
    final scanBtnText = _isScanning ? "Stop scanning" : "Scan for MeshNode";

    return Scaffold(
      appBar: AppBar(title: const Text("MeshNode")),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Status display
            Align(
              alignment: Alignment.centerLeft,
              child: Text("Status: $_status"),
            ),
            const SizedBox(height: 12),
            // Scan/stop button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _scanForMeshNode,
                child: Text(scanBtnText),
              ),
            ),

            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 8),
            // Node header
            Align(
              alignment: Alignment.centerLeft,
              child: Text("Connected / Added Nodes (${_nodes.length})",
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 8),
            // Node list
            Expanded(
              child: _nodes.isEmpty
                  ? const Center(child: Text("No nodes added yet."))
                  : ListView.separated(
                      itemCount: _nodes.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final n = _nodes[i];
                        return ListTile(
                          title: Text(n.name),
                          // subtitle with nodes info (name, ID, battery) Eventually (RSSI, GPS?, etc)
                         subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text("ID: ${n.deviceId}"),
                            Text("State: ${n.connState.name}"),
                            Text("Battery: ${n.batteryText} V"),
                            // Action row varies depending on connection state!!!!
                            Row(
                              children: [
                                if (n.connState == DeviceConnectionState.connected)
                                // If connected, only show disconnect button
                                  TextButton(
                                    onPressed: () => _disconnect(n),
                                    child: const Text("Disconnect"),
                                  )
                                else ...[
                                  // If not connceted, show reconnect and remove buttons
                                  TextButton(
                                    // Disable reconnect button during connection
                                    onPressed: n.connState == DeviceConnectionState.connecting
                                        ? null
                                        : () => _reconnect(n),
                                    child: const Text("Reconnect"),
                                  ),
                                  TextButton(
                                    onPressed: () => _removeNode(n),
                                    child: const Text("Remove"),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                          isThreeLine: false, 
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
