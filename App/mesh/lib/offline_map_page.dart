import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_mbtiles/flutter_map_mbtiles.dart';
import 'package:latlong2/latlong.dart';
import 'mbtiles_service.dart';

class OfflineMapView extends StatefulWidget {
  const OfflineMapView({super.key});

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
      return Container(
        color: Colors.white,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        child: Text(
          'Map failed to load:\n\n$_error',
          textAlign: TextAlign.center,
        ),
      );
    }

    if (_tileProvider == null) {
      return Container(
        color: Colors.white,
        alignment: Alignment.center,
        child: Text(_status),
      );
    }

    return FlutterMap(
      options: const MapOptions(
        initialCenter: LatLng(40.850444, -124.030750),
        initialZoom: 10,
      ),
      children: [
        TileLayer(
          tileProvider: _tileProvider!,
        ),
        MarkerLayer(
          markers: [
            Marker(
              point: LatLng(40.850444, -124.030750),
              width: 40,
              height: 40,
              child: const Icon(
                Icons.location_pin,
                color: Colors.red,
                size: 40,
              ),
            ),
          ],
        ),
      ],
    );
  }
}