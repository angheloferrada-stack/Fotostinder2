import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Limpia tu galería',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: const SwipePage(),
      );
}

/// Decisión tomada sobre un archivo: keep | delete | album
class _Decision {
  final AssetEntity asset;
  final String type;
  final String? album;
  _Decision(this.asset, this.type, [this.album]);
}

class SwipePage extends StatefulWidget {
  const SwipePage({super.key});

  @override
  State<SwipePage> createState() => _SwipePageState();
}

class _SwipePageState extends State<SwipePage> {
  static const int _pageSize = 60;
  static const double _threshold = 110;

  final List<AssetEntity> _assets = [];
  final List<_Decision> _history = [];
  final Set<String> _seen = {};
  List<String> _albums = [];
  AssetPathEntity? _all;
  late SharedPreferences _prefs;

  int _index = 0;
  int _page = 0;
  bool _hasMore = true;
  bool _loading = false;
  bool _checked = false;
  bool _permitted = false;
  bool _applying = false;
  String _status = '';
  Offset _drag = Offset.zero;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _prefs = await SharedPreferences.getInstance();
    _seen.addAll(_prefs.getStringList('seen') ?? []);
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) {
      setState(() {
        _checked = true;
        _permitted = false;
      });
      return;
    }
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common, // fotos + videos
      onlyAll: true,
    );
    if (paths.isNotEmpty) _all = paths.first;
    await _loadAlbums();
    await _loadMore();
    if (!mounted) return;
    setState(() {
      _checked = true;
      _permitted = true;
    });
  }

  Future<void> _loadAlbums() async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: false,
    );
    _albums = paths.map((p) => p.name).toList();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore || _all == null) return;
    _loading = true;
    final list = await _all!.getAssetListPaged(page: _page, size: _pageSize);
    _page++;
    if (list.length < _pageSize) _hasMore = false;
    final fresh = list.where((a) => !_seen.contains(a.id)).toList();
    _assets.addAll(fresh);
    _loading = false;
    if (fresh.isEmpty && _hasMore) {
      return _loadMore();
    }
    if (mounted) setState(() {});
  }

  Future<void> _saveSeen() async {
    await _prefs.setStringList('seen', _seen.toList());
  }

  // ---------- acciones ----------

  void _record(_Decision d) {
    _history.add(d);
    if (d.type == 'keep') {
      _seen.add(d.asset.id);
      _saveSeen();
    }
    setState(() {
      _index++;
      _drag = Offset.zero;
    });
    if (_assets.length - _index < 10) _loadMore();
  }

  void _keep() => _record(_Decision(_assets[_index], 'keep'));

  void _delete() => _record(_Decision(_assets[_index], 'delete'));

  void _undo() {
    if (_history.isEmpty || _index == 0) return;
    final d = _history.removeLast();
    _seen.remove(d.asset.id);
    _saveSeen();
    setState(() {
      _index--;
      _drag = Offset.zero;
    });
  }

  Future<void> _pickAlbum() async {
    final name = await _chooseAlbum();
    if (name == null) {
      setState(() => _drag = Offset.zero);
      return;
    }
    if (!_albums.contains(name)) _albums.add(name);
    _record(_Decision(_assets[_index], 'album', name));
  }

  void _onRelease() {
    final dx = _drag.dx;
    final dy = _drag.dy;
    if (dx > _threshold && dx.abs() > dy.abs()) {
      _keep();
    } else if (dx < -_threshold && dx.abs() > dy.abs()) {
      _delete();
    } else if (dy < -_threshold) {
      _pickAlbum();
    } else {
      setState(() => _drag = Offset.zero);
    }
  }

  Future<String?> _chooseAlbum() {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Nuevo álbum'),
              onTap: () async {
                final name = await _askName(ctx);
                if (!ctx.mounted) return;
                if (name != null && name.trim().isNotEmpty) {
                  Navigator.pop(ctx, name.trim());
                }
              },
            ),
            for (final a in _albums)
              ListTile(
                leading: const Icon(Icons.folder),
                title: Text(a),
                onTap: () => Navigator.pop(ctx, a),
              ),
          ],
        ),
      ),
    );
  }

  Future<String?> _askName(BuildContext ctx) {
    final c = TextEditingController();
    return showDialog<String>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: const Text('Nombre del álbum'),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, c.text),
            child: const Text('Crear'),
          ),
        ],
      ),
    );
  }

  /// Aplica todo junto: copia a álbumes y borra (una sola confirmación del sistema)
  Future<void> _apply() async {
    setState(() {
      _applying = true;
      _status = '';
    });
    final idsToDelete = <String>[];
    int moved = 0;
    int failed = 0;
    int done = 0;
    String lastError = '';
    final total = _history.where((d) => d.type != 'keep').length;
    try {
      for (final d in _history) {
        if (d.type == 'keep') continue;
        done++;
        if (mounted) setState(() => _status = 'Procesando $done de $total');
        if (d.type == 'delete') {
          idsToDelete.add(d.asset.id);
        } else if (d.type == 'album') {
          try {
            AssetEntity? saved;
            final dest = 'DCIM/${d.album}'; // DCIM acepta fotos y videos
            if (d.asset.type == AssetType.video) {
              final f = await d.asset.originFile;
              if (f != null) {
                saved = await PhotoManager.editor.saveVideo(
                  f,
                  title: d.asset.title ?? '${d.asset.id}.mp4',
                  relativePath: dest,
                );
              }
            } else {
              final bytes = await d.asset.originBytes;
              if (bytes != null) {
                saved = await PhotoManager.editor.saveImage(
                  bytes,
                  filename: d.asset.title ?? '${d.asset.id}.jpg',
                  relativePath: dest,
                );
              }
            }
            if (saved != null) {
              _seen.add(saved.id);
              idsToDelete.add(d.asset.id);
              moved++;
            } else {
              failed++;
            }
          } catch (e) {
            failed++;
            lastError = e.toString();
          }
        }
      }
      if (idsToDelete.isNotEmpty) {
        await PhotoManager.editor.deleteWithIds(idsToDelete);
      }
    } catch (e) {
      lastError = e.toString();
    }
    await _saveSeen();
    _history.clear();
    _assets.clear();
    _page = 0;
    _index = 0;
    _hasMore = true;
    _loading = false;
    await _loadAlbums();
    await _loadMore();
    if (!mounted) return;
    setState(() => _applying = false);
    final msg = failed > 0 || lastError.isNotEmpty
        ? 'Listo, pero hubo $failed fallas. Último error: $lastError'
        : 'Listo: $moved movidos, ${idsToDelete.length - moved} eliminados';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 8)),
    );
  }

  // ---------- interfaz ----------

  @override
  Widget build(BuildContext context) {
    if (!_checked) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_permitted) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Necesito acceso a tus fotos y videos'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: PhotoManager.openSetting,
                child: const Text('Abrir ajustes'),
              ),
            ],
          ),
        ),
      );
    }
    final pending = _history.where((d) => d.type != 'keep').length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Limpia tu galería'),
        actions: [
          TextButton(
            onPressed: (pending == 0 || _applying) ? null : _apply,
            child: Text('Aplicar ($pending)'),
          ),
        ],
      ),
      body: _applying
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(_status),
                ],
              ),
            )
          : _body(),
    );
  }

  Widget _body() {
    if (_index >= _assets.length) {
      if (_hasMore) {
        if (!_loading) Future.microtask(_loadMore);
        return const Center(child: CircularProgressIndicator());
      }
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '¡No quedan más archivos!\nToca "Aplicar" arriba para confirmar los cambios.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final cur = _assets[_index];
    final next = _index + 1 < _assets.length ? _assets[_index + 1] : null;
    final dx = _drag.dx;
    final dy = _drag.dy;

    return Column(
      children: [
        Expanded(
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (next != null)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: _Media(next, key: ValueKey('n${next.id}')),
                ),
              GestureDetector(
                onPanUpdate: (d) => setState(() => _drag += d.delta),
                onPanEnd: (_) => _onRelease(),
                child: Transform.translate(
                  offset: _drag,
                  child: Transform.rotate(
                    angle: dx / 1200,
                    child: Stack(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: _Media(
                            cur,
                            play: true,
                            key: ValueKey('c${cur.id}'),
                          ),
                        ),
                        Positioned(
                          top: 40,
                          left: 40,
                          child: _label('CONSERVAR', Colors.green,
                              dx > 0 ? (dx / 120).clamp(0.0, 1.0).toDouble() : 0.0),
                        ),
                        Positioned(
                          top: 40,
                          right: 40,
                          child: _label('ELIMINAR', Colors.red,
                              dx < 0 ? (-dx / 120).clamp(0.0, 1.0).toDouble() : 0.0),
                        ),
                        Positioned(
                          bottom: 40,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: _label('ÁLBUM', Colors.blue,
                                dy < 0 ? (-dy / 120).clamp(0.0, 1.0).toDouble() : 0.0),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 24, top: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton.filled(
                onPressed: _delete,
                icon: const Icon(Icons.close),
                iconSize: 32,
              ),
              IconButton(
                onPressed: _undo,
                icon: const Icon(Icons.undo),
                iconSize: 28,
              ),
              IconButton(
                onPressed: _pickAlbum,
                icon: const Icon(Icons.folder),
                iconSize: 28,
              ),
              IconButton.filled(
                onPressed: _keep,
                icon: const Icon(Icons.check),
                iconSize: 32,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _label(String text, Color color, double opacity) => Opacity(
        opacity: opacity,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            border: Border.all(color: color, width: 3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      );
}

String _fmt(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
}

/// Muestra una foto o un video (el video se reproduce solo si play = true)
class _Media extends StatefulWidget {
  final AssetEntity asset;
  final bool play;
  const _Media(this.asset, {this.play = false, super.key});

  @override
  State<_Media> createState() => _MediaState();
}

class _MediaState extends State<_Media> {
  late final Future<Uint8List?> _thumb =
      widget.asset.thumbnailDataWithSize(const ThumbnailSize(900, 900));
  VideoPlayerController? _ctrl;
  bool _muted = true;

  bool get _isVideo => widget.asset.type == AssetType.video;

  @override
  void initState() {
    super.initState();
    if (widget.play && _isVideo) _initVideo();
  }

  Future<void> _initVideo() async {
    final File? file = await widget.asset.originFile;
    if (file == null || !mounted) return;
    final c = VideoPlayerController.file(file);
    try {
      await c.initialize();
    } catch (_) {
      await c.dispose();
      return;
    }
    if (!mounted) {
      await c.dispose();
      return;
    }
    await c.setLooping(true);
    await c.setVolume(0);
    await c.play();
    setState(() => _ctrl = c);
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _ctrl;
    final ready = c != null && c.value.isInitialized;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<Uint8List?>(
            future: _thumb,
            builder: (context, snap) {
              final data = snap.data;
              if (data == null) {
                return const Center(child: CircularProgressIndicator());
              }
              return Image.memory(
                data,
                fit: BoxFit.contain,
                gaplessPlayback: true,
              );
            },
          ),
          if (ready)
            Center(
              child: AspectRatio(
                aspectRatio: c.value.aspectRatio,
                child: VideoPlayer(c),
              ),
            ),
          if (_isVideo)
            Positioned(
              bottom: 8,
              left: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.videocam, size: 16),
                    const SizedBox(width: 4),
                    Text(_fmt(widget.asset.videoDuration)),
                  ],
                ),
              ),
            ),
          if (ready)
            Positioned(
              bottom: 0,
              right: 0,
              child: IconButton(
                onPressed: () {
                  setState(() => _muted = !_muted);
                  c.setVolume(_muted ? 0 : 1);
                },
                icon: Icon(_muted ? Icons.volume_off : Icons.volume_up),
              ),
            ),
        ],
      ),
    );
  }
}
