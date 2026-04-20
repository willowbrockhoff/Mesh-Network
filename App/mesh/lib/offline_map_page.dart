import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_mbtiles/flutter_map_mbtiles.dart';
import 'package:latlong2/latlong.dart';
import 'mbtiles_service.dart';

// Node GPS -> pin on map struct
class MapPinData {
  final String id;
  final String label;
  final double latitude;
  final double longitude;

  const MapPinData({
    required this.id,
    required this.label,
    required this.latitude,
    required this.longitude
  });
}

class OfflineMapView extends StatefulWidget {
  final List<MapPinData> pins;

  const OfflineMapView({
    super.key,
    this.pins = const []
  });

  @override
  State<OfflineMapView> createState() => _OfflineMapViewState();
}

class _OfflineMapViewState extends State<OfflineMapView> {
  MbTilesTileProvider? _tileProvider;
  String? _error;
  String _status = 'Preparing offline map...';

  @override
  void initState() {
    super.initState();
    _initMap();
  }

  Future<void> _initMap() async {
    try {
      setState(() {
        _status = 'Copying MBTiles file...';
      });

      final localPath = await MbtilesService.copyAssetToFileSystem(
        'assets/maps/satellite-2017-11-02_california_humboldt.mbtiles',
        //'satellite-2017-11-02_california_humboldt.mbtiles',
        //'assets/maps/ncds_20a.mbtiles',
        'satellite-2017-11-02_california_humboldt.mbtiles',
      );

      debugPrint('MBTiles local path: $localPath');

      setState(() {
        _status = 'Opening tile provider...';
      });

      final tileProvider = MbTilesTileProvider.fromPath(path: localPath);

      if (!mounted) {
        tileProvider.dispose();
        return;
      }

      setState(() {
        _tileProvider = tileProvider;
        _status = 'Ready';
      });
    } catch (e, st) {
      debugPrint('Offline map init error: $e');
      debugPrintStack(stackTrace: st);

      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _status = 'Failed';
      });
    }
  }

  @override
  void dispose() {
    _tileProvider?.dispose();
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

    if (_tileProvider == null) {
      return Center(child: Text(_status));
    }

    final LatLng center = widget.pins.isNotEmpty
      ? LatLng(widget.pins.first.latitude, widget.pins.first.longitude)
      : const LatLng(39.73248, -12184437);

    return FlutterMap(
        options: MapOptions(
          initialCenter: LatLng(40.850444, -124.030750),
          initialZoom: 14,
        ),
        children: [
          TileLayer(
            tileProvider: _tileProvider!,
          ),
          MarkerLayer(
            markers: widget.pins.map((pin){
              return Marker(
                point: LatLng(pin.latitude, pin.longitude), // test marker for humbolt dataset
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
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}