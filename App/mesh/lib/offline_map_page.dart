import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_map_tiles_mbtiles/vector_map_tiles_mbtiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr hide TileLayer;
import 'package:mbtiles/mbtiles.dart';
import 'mbtiles_service.dart';

// Represents pins displayed on map
class MapPinData {
  final String id;
  final String label;
  final double latitude;
  final double longitude;

  const MapPinData({
    required this.id,
    required this.label,
    required this.latitude,
    required this.longitude,
  });
}

// Widget that displays an offline vector map backed by a local MBTiles file
// Pins sent from WilderMesh nodes are displayed
class OfflineMapView extends StatefulWidget {
  final List<MapPinData> pins;

  const OfflineMapView({
    super.key,
    this.pins = const [],
  });

  @override
  State<OfflineMapView> createState() => _OfflineMapViewState();
}

class _OfflineMapViewState extends State<OfflineMapView> {
  
  MbTilesVectorTileProvider? _tileProvider;
  // Raw database
  MbTiles? _mbTiles;
  // Parsed map theme from /assets/styles/style.json
  vtr.Theme? _theme;
  // Holds errors to display in UI
  Object? _error;
  String _status = 'Preparing offline map...';

  @override
  void initState() {
    super.initState();
    _initMap();
  }

  // Initalizes offline map by
  // - Copying mbtiles to local storage
  // - Opening mbtile database
  // - Creating vector tile provider
  // - Loading/parsing style.json
  Future<void> _initMap() async {
    try {
      setState(() {
        _status = 'Copying MBTiles file...';
      });

      // Copy mbtiles to local path
      final localPath = await MbtilesService.copyAssetToFileSystem(
        'assets/maps/butte_co.mbtiles',
        'butte_co_debug_${DateTime.now().millisecondsSinceEpoch}.mbtiles',
      );
      // Open mbtiles database
      final mbTiles = MbTiles(
        mbtilesPath: localPath,
      );
      // Create vector tile provider that reads from database
      final tileProvider = MbTilesVectorTileProvider(
        mbtiles: mbTiles,
        silenceTileNotFound: true,  // Avoids debug noise
      );

      setState(() {
        _status = 'Loading style asset...';
      });

      // Load, decode, and parse style/theme
      final styleRaw = await rootBundle.loadString('assets/styles/style.json');
      final styleJson = jsonDecode(styleRaw) as Map<String, dynamic>;
      final theme = vtr.ThemeReader().read(styleJson);

      if (!mounted) return;
      
      // Save for rendering
      setState(() {
        _mbTiles = mbTiles;
        _tileProvider = tileProvider;
        _theme = theme;
        _status = 'Ready';
      });
    } catch (e, st) {
      debugPrint('Offline map init error: $e');
      debugPrintStack(stackTrace: st);

      if (!mounted) return;
      setState(() {
        _error = e;
        _status = 'Failed';
      });
    }
  }

  @override
  void dispose() {
    // Release database in destruction
    _mbTiles?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Map failed to load:\n\n$_error'),
      );
    }
    // While loading show the status to UI
    if (_tileProvider == null || _theme == null) {
      return Center(child: Text(_status));
    }

    // After init, render offline
    return FlutterMap(
      options: const MapOptions(
        // Center map in Chico
        initialCenter: LatLng(39.739581, -121.834236),
        initialZoom: 14,
        maxZoom: 18,
      ),
      children: [
        // Vector tile layer renders from device local mbtile src using theme/style
        VectorTileLayer(
          tileProviders: TileProviders({
            'openmaptiles': _tileProvider!,
          }),
          theme: _theme!,
          maximumZoom: 18,
          tileOffset: TileOffset.mapbox,
          layerMode: VectorTileLayerMode.vector,
        ),
        // Display pins location when avaliable
        MarkerLayer(
          markers: (() {
            final List<Marker> markers = [];
            // Add dynamic markers
            for (var pin in widget.pins) {
              markers.add(
                Marker(
                  point: LatLng(pin.latitude, pin.longitude),
                  width: 90,
                  height: 70,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.location_pin,
                        color: Colors.red,
                        size: 40,
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(220),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          pin.label,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 7,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }
            return markers;
          })(),
        ),
      ],
    );
  }
}