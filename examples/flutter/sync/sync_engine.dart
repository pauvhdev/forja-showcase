import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../local/app_database.dart';
import '../repositories/media_repository.dart';
import 'entity_mappers.dart';
import 'outbox.dart';
import 'reconcile.dart';

enum SyncPhase { idle, pushing, pulling, offline, failed }

class SyncStatus {
  const SyncStatus({
    this.phase = SyncPhase.idle,
    this.pending = 0,
    this.lastSyncedAt,
    this.error,
    this.subidas = 0,
  });

  final SyncPhase phase;
  final int pending;
  final DateTime? lastSyncedAt;
  final String? error;

  /// Cuántas vueltas han subido algo. Lo social se pide al servidor, y no se
  /// entera solo de que acabas de cerrar una sesión o apuntar una serie: lo
  /// que lo enseña vuelve a pedirse cuando esto cambia (`datosSubidosProvider`).
  final int subidas;

  bool get isBusy => phase == SyncPhase.pushing || phase == SyncPhase.pulling;

  SyncStatus copyWith({
    SyncPhase? phase,
    int? pending,
    DateTime? lastSyncedAt,
    String? error,
    bool clearError = false,
    int? subidas,
  }) => SyncStatus(
    phase: phase ?? this.phase,
    pending: pending ?? this.pending,
    lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
    error: clearError ? null : (error ?? this.error),
    subidas: subidas ?? this.subidas,
  );
}

/// Sincronización bidireccional entre SQLite y Supabase.
///
/// Primero sube (push) y luego baja (pull), siempre en ese orden: si bajáramos
/// antes, el servidor nos devolvería una versión antigua de filas que tenemos
/// pendientes de subir y el pull las machacaría.
///
/// Reglas de conflicto, en una frase: **gana lo local mientras esté pendiente
/// de subir**. Como cada fila la edita una sola persona (tus series son tuyas),
/// no hace falta nada más sofisticado que eso.
class SyncEngine {
  SyncEngine({
    required AppDatabase db,
    required SupabaseClient client,
    required Outbox outbox,
  }) : _db = db,
       _client = client,
       _outbox = outbox;

  final AppDatabase _db;
  final SupabaseClient _client;
  final Outbox _outbox;

  static const _pageSize = 500;
  static const _maxAttempts = 5;

  /// Solape al bajar: se piden los cambios desde (cursor − 2 s) en vez de
  /// exactamente desde el cursor. Dos filas escritas en el mismo milisegundo
  /// podrían quedarse al otro lado del corte. El upsert es idempotente, así
  /// que repetir unas pocas filas no cuesta nada.
  static const _overlap = Duration(seconds: 2);

  final _statusController = StreamController<SyncStatus>.broadcast();
  SyncStatus _status = const SyncStatus();

  Stream<SyncStatus> get status => _statusController.stream;
  SyncStatus get currentStatus => _status;

  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  StreamSubscription<int>? _pendingSub;
  bool _running = false;

  /// Alguien pidió sincronizar mientras ya se estaba haciendo. Sin esto, lo
  /// que se encolaba durante la bajada (cerrar la sesión justo entonces)
  /// esperaba al siguiente disparo, hasta 2 minutos.
  bool _otraVez = false;

  void _emit(SyncStatus s) {
    _status = s;
    if (!_statusController.isClosed) _statusController.add(s);
  }

  /// Arranca el ciclo automático: cada 2 minutos, al recuperar conexión, y
  /// cada vez que aparece algo nuevo en la cola.
  void start() {
    _timer ??= Timer.periodic(const Duration(minutes: 2), (_) => syncNow());

    _connSub ??= Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online) syncNow();
    });

    _pendingSub ??= _outbox.watchPendingCount().listen((n) {
      _emit(_status.copyWith(pending: n));
      if (n > 0) syncNow();
    });
  }

  Future<void> dispose() async {
    _timer?.cancel();
    await _connSub?.cancel();
    await _pendingSub?.cancel();
    await _statusController.close();
  }

  /// Un ciclo completo. Si ya hay uno en marcha, no encola otro: el siguiente
  /// disparo lo recogerá.
  Future<void> syncNow() async {
    if (_running) {
      _otraVez = true;
      return;
    }
    if (_client.auth.currentUser == null) return;

    final conn = await Connectivity().checkConnectivity();
    if (conn.every((r) => r == ConnectivityResult.none)) {
      _emit(_status.copyWith(phase: SyncPhase.offline));
      return;
    }

    _running = true;
    _otraVez = false;
    try {
      _emit(_status.copyWith(phase: SyncPhase.pushing, clearError: true));
      final subidas = await _push();

      _emit(_status.copyWith(phase: SyncPhase.pulling));
      await _pull();
      await _reconcile();

      _emit(
        _status.copyWith(
          phase: SyncPhase.idle,
          lastSyncedAt: DateTime.now(),
          clearError: true,
          subidas: subidas > 0 ? _status.subidas + 1 : null,
        ),
      );
    } catch (e) {
      _emit(_status.copyWith(phase: SyncPhase.failed, error: e.toString()));
    } finally {
      _running = false;
    }
    if (_otraVez) await syncNow();
  }

  /// Clave de `app_settings` con la sesión cuya corrección llegó tarde. La
  /// lee `AvisoCorreccionTarde`, que la borra al darle a "Entendido".
  static const claveCorreccionTarde = 'aviso:correccion_tarde';

  /// El servidor no aceptó un cambio a una serie de una sesión cerrada. En el
  /// móvil se vuelve a lo que tiene él (la serie y los totales de la sesión),
  /// y si era una corrección, se avisa: se hizo sin internet y subió pasadas
  /// las 24 h, o ya con las 3 gastadas.
  Future<void> _rechazoDeSesionCerrada(Map<String, dynamic> serie) async {
    final workoutId = serie['workout_id']?.toString();
    try {
      for (final (tabla, id) in [
        ('workout_sets', serie['id']?.toString()),
        ('workouts', workoutId),
      ]) {
        if (id == null) continue;
        final filas = await _client.from(tabla).select().eq('id', id);
        final spec = pullSpecs.firstWhere((s) => s.remoteTable == tabla);
        await spec.apply(_db, filas.cast<Map<String, dynamic>>(), const {});
      }
    } catch (_) {
      // Sin red a mitad: la siguiente bajada completa lo arregla igual.
    }
    if (serie['edicion_id'] != null && workoutId != null) {
      await _db
          .into(_db.appSettings)
          .insertOnConflictUpdate(
            AppSettingsCompanion.insert(
              key: claveCorreccionTarde,
              value: workoutId,
            ),
          );
    }
  }

  // ── PUSH ────────────────────────────────────────────────────────────────
  /// Sube la cola. Devuelve cuántas entradas han llegado al servidor.
  Future<int> _push() async {
    var subidas = 0;
    while (true) {
      final batch = await _outbox.nextBatch();
      if (batch.isEmpty) return subidas;

      var progressed = false;

      for (final entry in batch) {
        try {
          final payload = jsonDecode(entry.payload) as Map<String, dynamic>;

          if (entry.entity == Media.entidadFotoEntreno) {
            await _subirFichero(payload);
          } else if (entry.op == OutboxOp.delete.name) {
            await _client.from(entry.entity).delete().eq('id', entry.rowId);
          } else {
            await _client.from(entry.entity).upsert(payload);
          }

          await _outbox.markDone(entry.seq, enviado: entry.payload);
          subidas++;
          progressed = true;
        } on PostgrestException catch (e) {
          // Un cambio a una serie de una sesión ya cerrada: el servidor tiene
          // la buena y no va a aceptarlo nunca. Bloqueado solo sirve para
          // pintar "sin subir" en rojo para siempre (Guillem, 27/10), así que
          // se tira, con lo que venga detrás para esa misma serie.
          if (entry.entity == 'workout_sets' &&
              e.message.contains('sesión completada')) {
            await _outbox.descartarFila(entry.seq, entry.rowId);
            await _rechazoDeSesionCerrada(
              jsonDecode(entry.payload) as Map<String, dynamic>,
            );
            progressed = true;
            continue;
          }
          // El servidor contestó y dijo que no: RLS, validación, o el trigger
          // que bloquea sesiones completadas. Reintentar no lo arregla.
          await _outbox.markBlocked(
            entry.seq,
            '${e.code ?? ''} ${e.message}'.trim(),
          );
          // Y con ella, todo lo que la referencie. Si no, la asignación de una
          // rutina que no ha subido llega al servidor apuntando a nada y el
          // error de clave foránea tapa la causa de verdad.
          await _outbox.blockDependents(entry.seq, entry.rowId);
          progressed = true;
        } on StorageException catch (e) {
          // Lo mismo para un fichero: un 4xx (sin permiso, demasiado grande,
          // formato que el bucket no acepta) no se arregla reintentando. Un
          // 5xx o un 429, sí.
          final codigo = int.tryParse(e.statusCode ?? '') ?? 0;
          if (codigo >= 400 && codigo < 500 && codigo != 408 && codigo != 429) {
            await _outbox.markBlocked(entry.seq, 'Foto: $codigo ${e.message}');
            progressed = true;
          } else {
            await _outbox.bumpAttempts(entry.seq, e.toString());
            if (entry.attempts + 1 < _maxAttempts) return subidas;
            await _outbox.markBlocked(
              entry.seq,
              'Sin éxito tras $_maxAttempts intentos: $e',
            );
            progressed = true;
          }
        } catch (e) {
          // Red caída, DNS, timeout: transitorio. Se reintenta.
          await _outbox.bumpAttempts(entry.seq, e.toString());
          if (entry.attempts + 1 >= _maxAttempts) {
            await _outbox.markBlocked(
              entry.seq,
              'Sin éxito tras $_maxAttempts intentos: $e',
            );
            progressed = true;
          } else {
            // La cola es ordenada: si esta no sube, las siguientes tampoco
            // deben adelantarla (podrían depender de ella).
            return subidas;
          }
        }
      }

      if (!progressed) return subidas;
    }
  }

  /// Una foto de la cola: primero el fichero, luego la fila que lo anuncia.
  /// Con upsert en los dos, así que un reintento tras cortarse a medias no
  /// choca con lo que ya llegó.
  Future<void> _subirFichero(Map<String, dynamic> p) async {
    await _client.storage
        .from(Media.bucket)
        .uploadBinary(
          p['ruta'] as String,
          base64Decode(p['datos'] as String),
          fileOptions: FileOptions(
            contentType: p['tipo'] as String,
            upsert: true,
          ),
        );
    await _client
        .from(p['tabla'] as String)
        .upsert(p['fila'] as Map<String, dynamic>);
  }

  // ── PULL ────────────────────────────────────────────────────────────────
  Future<void> _pull() async {
    for (final spec in pullSpecs) {
      final cursor = await _cursorFor(spec.remoteTable);
      final since = cursor?.subtract(_overlap);
      final skip = await _outbox.pendingRowIds(spec.remoteTable);

      DateTime? newest = cursor;
      var offset = 0;

      while (true) {
        var query = _client.from(spec.remoteTable).select();
        if (since != null) {
          query = query.gte('updated_at', since.toUtc().toIso8601String());
        }

        final rows = await query
            .order('updated_at', ascending: true)
            .range(offset, offset + _pageSize - 1);

        final list = rows.cast<Map<String, dynamic>>();
        if (list.isEmpty) break;

        await spec.apply(_db, list, skip);

        for (final r in list) {
          final ts = DateTime.tryParse(r['updated_at']?.toString() ?? '');
          if (ts != null && (newest == null || ts.isAfter(newest))) {
            newest = ts;
          }
        }

        if (list.length < _pageSize) break;
        offset += _pageSize;
      }

      if (newest != null) {
        await _setCursor(spec.remoteTable, newest);
      }
    }
  }

  /// Quita de aquí lo que se ha borrado en otro dispositivo. Por qué y con qué
  /// cuidado, en reconcile.dart.
  ///
  /// Va después de subir y de bajar: así lo que este dispositivo tenía
  /// pendiente ya está arriba, y lo que queda en la cola está protegido.
  Future<void> _reconcile() async {
    for (final tabla in tablasConBorrados) {
      final enServidor = await _idsEnServidor(tabla);
      await quitarBorradosFuera(
        _db,
        tabla,
        enServidor: enServidor,
        pendientes: () => _outbox.pendingRowIds(tabla),
      );
    }
  }

  /// Todos los ids de la tabla que este usuario puede ver en el servidor.
  ///
  /// Entero o nada: si una página falla, lanza y no se borra nada. Y ordenado
  /// por id: paginando sin orden, una fila podía caer entre dos páginas,
  /// parecer borrada y desaparecer de este dispositivo sin estarlo.
  Future<Set<String>> _idsEnServidor(String tabla) async {
    final ids = <String>{};
    var offset = 0;
    while (true) {
      final filas = await _client
          .from(tabla)
          .select('id')
          .order('id', ascending: true)
          .range(offset, offset + _pageSize - 1);
      final lista = filas.cast<Map<String, dynamic>>();
      ids.addAll(lista.map((f) => f['id'] as String));
      if (lista.length < _pageSize) break;
      offset += _pageSize;
    }
    return ids;
  }

  Future<DateTime?> _cursorFor(String entity) async {
    final row = await (_db.select(
      _db.syncCursors,
    )..where((t) => t.entity.equals(entity))).getSingleOrNull();
    return row?.lastPulledAt;
  }

  Future<void> _setCursor(String entity, DateTime at) => _db
      .into(_db.syncCursors)
      .insertOnConflictUpdate(
        SyncCursorsCompanion.insert(entity: entity, lastPulledAt: Value(at)),
      );

  /// Fuerza una bajada completa (p. ej. tras vincularse a un coach y ganar
  /// acceso a filas que antes el RLS ocultaba).
  Future<void> resetCursors() async {
    await _db.delete(_db.syncCursors).go();
    await syncNow();
  }
}
