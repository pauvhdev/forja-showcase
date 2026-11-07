import 'dart:convert';

import 'package:drift/drift.dart';

import '../local/app_database.dart';

/// Operaciones soportadas por la cola de salida.
enum OutboxOp { upsert, delete }

/// La cola de salida.
///
/// Contrato: una escritura local NUNCA falla. Se guarda en SQLite y se encola
/// aquí; subirla es problema del [SyncEngine], que reintentará cuando haya
/// red. La UI no espera a la nube para dar feedback.
class Outbox {
  Outbox(this._db);

  final AppDatabase _db;

  /// Encola un upsert. [payload] ya debe venir con los nombres de columna del
  /// servidor (snake_case) y los tipos serializados.
  ///
  /// [fusionarSoloCon]: se fusiona con la entrada pendiente de la fila solo
  /// si esa ya lleva este texto; si no, va al final de la cola. Para lo que
  /// tiene que subir DESPUÉS de lo que hay en medio: cerrar una sesión
  /// entrenada sin red (si el cierre se fundía con la primera entrada, la
  /// sesión llegaba cerrada antes que sus series y el candado las rechazaba)
  /// o corregirla (los cambios, detrás de la corrección).
  Future<void> enqueueUpsert({
    required String entity,
    required String rowId,
    required Map<String, dynamic> payload,
    String? fusionarSoloCon,
  }) => _enqueue(entity, OutboxOp.upsert, rowId, payload, fusionarSoloCon);

  Future<void> enqueueDelete({required String entity, required String rowId}) =>
      _enqueue(entity, OutboxOp.delete, rowId, {'id': rowId});

  Future<void> _enqueue(
    String entity,
    OutboxOp op,
    String rowId,
    Map<String, dynamic> payload, [
    String? fusionarSoloCon,
  ]) async {
    // Coalescencia: si ya hay un upsert pendiente de esta misma fila y aún no
    // se ha intentado subir, se reemplaza en vez de acumular otro.
    //
    // Sin esto, teclear "100" en una celda de peso encolaría tres mutaciones
    // (1, 10, 100) y subiríamos tres veces la misma serie. Con sesiones de 40
    // series eso son cientos de peticiones inútiles.
    if (op == OutboxOp.upsert) {
      final pending =
          await (_db.select(_db.outboxEntries)
                ..where(
                  (t) =>
                      t.rowId.equals(rowId) &
                      t.entity.equals(entity) &
                      t.op.equals(OutboxOp.upsert.name) &
                      t.attempts.equals(0) &
                      t.isBlocked.equals(false),
                )
                ..orderBy([(t) => OrderingTerm.desc(t.seq)])
                ..limit(1))
              .getSingleOrNull();

      if (pending != null &&
          (fusionarSoloCon == null ||
              pending.payload.contains(fusionarSoloCon))) {
        await (_db.update(
          _db.outboxEntries,
        )..where((t) => t.seq.equals(pending.seq))).write(
          OutboxEntriesCompanion(
            payload: Value(jsonEncode(payload)),
            createdAt: Value(DateTime.now()),
          ),
        );
        return;
      }
    }

    await _db
        .into(_db.outboxEntries)
        .insert(
          OutboxEntriesCompanion.insert(
            entity: entity,
            op: op.name,
            rowId: rowId,
            payload: jsonEncode(payload),
            createdAt: DateTime.now(),
          ),
        );
  }

  /// Siguiente lote a subir, en orden de creación. El orden importa: una
  /// serie no se puede insertar antes que su sesión padre.
  Future<List<OutboxEntry>> nextBatch({int limit = 100}) {
    return (_db.select(_db.outboxEntries)
          ..where((t) => t.isBlocked.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.seq)])
          ..limit(limit))
        .get();
  }

  /// Quita de la cola lo que ya ha subido. Con [enviado], solo si la entrada
  /// sigue llevando eso: mientras subía, la coalescencia de [_enqueue] pudo
  /// meterle un cambio más nuevo (la entrada aún tiene 0 intentos), y
  /// borrarla tiraba ese cambio sin subirlo. Luego el pull bajaba la versión
  /// vieja y machacaba la buena: "cambio de por lado a total y no se guarda".
  /// Si cambió, se queda y sube en la siguiente vuelta.
  Future<void> markDone(int seq, {String? enviado}) =>
      (_db.delete(_db.outboxEntries)..where(
            (t) =>
                t.seq.equals(seq) &
                (enviado == null
                    ? const Constant(true)
                    : t.payload.equals(enviado)),
          ))
          .go();

  /// Tira la entrada [seq] y las que vengan detrás para la misma fila: un
  /// cambio que el servidor no va a aceptar nunca.
  Future<void> descartarFila(int seq, String rowId) =>
      (_db.delete(_db.outboxEntries)..where(
            (t) =>
                t.seq.equals(seq) |
                (t.seq.isBiggerThanValue(seq) & t.rowId.equals(rowId)),
          ))
          .go();

  /// Fallo transitorio (sin red, 5xx): se queda en la cola para el próximo intento.
  Future<void> markRetryable(int seq, String error) =>
      (_db.update(_db.outboxEntries)..where((t) => t.seq.equals(seq))).write(
        OutboxEntriesCompanion(
          attempts: const Value.absent(),
          lastError: Value(error),
        ),
      );

  Future<void> bumpAttempts(int seq, String error) async {
    final row = await (_db.select(
      _db.outboxEntries,
    )..where((t) => t.seq.equals(seq))).getSingleOrNull();
    if (row == null) return;
    await (_db.update(
      _db.outboxEntries,
    )..where((t) => t.seq.equals(seq))).write(
      OutboxEntriesCompanion(
        attempts: Value(row.attempts + 1),
        lastError: Value(error),
      ),
    );
  }

  /// Fallo permanente (4xx: RLS, validación, fila bloqueada por ser sesión
  /// completada). Reintentar no lo va a arreglar y taponaría la cola entera,
  /// así que se aparta y se le enseña al usuario.
  Future<void> markBlocked(int seq, String error) =>
      (_db.update(_db.outboxEntries)..where((t) => t.seq.equals(seq))).write(
        OutboxEntriesCompanion(
          isBlocked: const Value(true),
          lastError: Value(error),
        ),
      );

  /// Aparta también lo que dependa de una fila que no ha podido subir.
  ///
  /// Sin esto, bloquear una rutina dejaba pasar su asignación, que llegaba al
  /// servidor apuntando a una rutina que no existe. El usuario acababa viendo
  /// un error de clave foránea —la consecuencia— mientras la causa real
  /// quedaba enterrada en una entrada más vieja.
  ///
  /// La dependencia se detecta buscando el id dentro del payload. Son uuid:
  /// que aparezcan ahí significa que se les apunta.
  Future<int> blockDependents(int afterSeq, String rowId) async {
    final siguientes =
        await (_db.select(_db.outboxEntries)..where(
              (t) =>
                  t.seq.isBiggerThanValue(afterSeq) & t.isBlocked.equals(false),
            ))
            .get();

    var bloqueadas = 0;
    for (final e in siguientes) {
      if (e.rowId == rowId || e.payload.contains(rowId)) {
        await markBlocked(e.seq, 'Depende de otro cambio que no pudo subir');
        bloqueadas++;
      }
    }
    return bloqueadas;
  }

  /// Devuelve a la cola lo apartado.
  ///
  /// Casi siempre la causa de un bloqueo se corrige fuera de la app —una
  /// política de RLS, un permiso—, y entonces tirar los datos es absurdo:
  /// pueden ser entrenos de verdad.
  Future<void> retryBlocked() =>
      (_db.update(
        _db.outboxEntries,
      )..where((t) => t.isBlocked.equals(true))).write(
        const OutboxEntriesCompanion(
          isBlocked: Value(false),
          attempts: Value(0),
        ),
      );

  /// Ids con escrituras pendientes. El pull no debe pisarlos: lo local es más
  /// nuevo que lo que hay en el servidor.
  Future<Set<String>> pendingRowIds(String entity) async {
    final rows = await (_db.select(
      _db.outboxEntries,
    )..where((t) => t.entity.equals(entity))).get();
    return rows.map((r) => r.rowId).toSet();
  }

  Stream<int> watchPendingCount() {
    final q = _db.selectOnly(_db.outboxEntries)
      ..addColumns([_db.outboxEntries.seq.count()])
      ..where(_db.outboxEntries.isBlocked.equals(false));
    return q
        .map((r) => r.read(_db.outboxEntries.seq.count()) ?? 0)
        .watchSingle();
  }

  Stream<List<OutboxEntry>> watchBlocked() =>
      (_db.select(_db.outboxEntries)
            ..where((t) => t.isBlocked.equals(true))
            ..orderBy([(t) => OrderingTerm.desc(t.seq)]))
          .watch();

  Future<void> discardBlocked() => (_db.delete(
    _db.outboxEntries,
  )..where((t) => t.isBlocked.equals(true))).go();
}
