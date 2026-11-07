import 'dart:math' as math;

/// Estimación del 1RM (repetición máxima) a partir de una serie submáxima.
///
/// Ojo con los nombres, porque se confunden constantemente:
///
///   · **Epley**   → `w × (1 + reps/30)`   ← la que usa esta app
///   · **Brzycki** → `w × 36 / (37 − reps)`
///
/// Son fórmulas distintas y dan resultados distintos: con 100 kg × 8 reps,
/// Epley estima 126,7 kg y Brzycki 124,1 kg. Ninguna es "la correcta"; lo
/// importante es usar siempre la misma para que la progresión sea comparable.
///
/// Esta app usa **Epley** en todas partes, incluidas las columnas generadas
/// `workout_sets.estimated_1rm` y `challenge_marks.estimated_1rm` de Postgres.
/// Si algún día se cambia, hay que cambiarla en los tres sitios a la vez o el
/// histórico y los retos dejan de cuadrar.
///
/// Desde la 1.24.0 las series con RPE/RIR suman las reps que sobraban
/// ([OneRepMax.estimate]); las marcas de reto no llevan esfuerzo y siguen
/// con Epley a secas.
class OneRepMax {
  const OneRepMax._();

  /// Por encima de este número de repeticiones la estimación deja de ser
  /// fiable (el fallo pasa a ser metabólico, no neuromuscular).
  static const maxReliableReps = 15;

  /// Epley. Devuelve null si los datos no permiten una estimación creíble.
  static double? epley(double? weightKg, int? reps) {
    if (weightKg == null || reps == null) return null;
    if (weightKg <= 0 || reps < 1 || reps > maxReliableReps) return null;
    return weightKg * (1 + reps / 30.0);
  }

  /// Brzycki. Disponible para comparar, no se usa por defecto.
  static double? brzycki(double? weightKg, int? reps) {
    if (weightKg == null || reps == null) return null;
    if (weightKg <= 0 || reps < 1 || reps > math.min(maxReliableReps, 36)) {
      return null;
    }
    return weightKg * 36.0 / (37.0 - reps);
  }

  /// Las reps que te quedaban en la recámara con [rpe] (RIR = 10 − RPE).
  /// Se cuentan hasta [maxRir]: por debajo de RPE 6 nadie atina cuántas le
  /// sobraban, y estimar el máximo de una serie fácil infla el 1RM.
  static double rir(double? rpe) =>
      rpe == null ? 0 : (10 - rpe).clamp(0, maxRir).toDouble();

  static const maxRir = 4.0;

  /// La fórmula oficial de la app. Un único punto de verdad.
  ///
  /// Con el esfuerzo apuntado ([rpe]), cuentan también las reps que te
  /// sobraban: 100 × 5 a RIR 2 es como 100 × 7 hasta el fallo (lo pidieron
  /// Guillem y Lucas). Sin él, Epley de siempre. Las reps hechas siguen
  /// teniendo que estar entre 1 y [maxReliableReps], y con las de la recámara
  /// no se pasa de ahí. Igual que `workout_sets.estimated_1rm` (sección 42
  /// de `parche.sql`).
  static double? estimate(double? weightKg, int? reps, {double? rpe}) {
    if (epley(weightKg, reps) == null) return null;
    final efectivas = math.min(reps! + rir(rpe), maxReliableReps.toDouble());
    return weightKg! * (1 + efectivas / 30.0);
  }

  /// Lo que tiene que superar cada serie de un ejercicio para ser RÉCORD:
  /// lo mejor de las sesiones de antes ([historico]) y lo de las series ya
  /// hechas antes en ESTA sesión. Sin esto, 100×5 dos veces seguidas salían
  /// las dos como récord.
  ///
  /// Hay que superarlo, no igualarlo: repetir la marca no es otro récord.
  static List<double?> listones(
    double? historico,
    List<({bool hecha, double? peso, int? reps, double? rpe})> series,
  ) {
    var mejor = historico;
    return [
      for (final s in series)
        () {
          final liston = mejor;
          final e = s.hecha ? estimate(s.peso, s.reps, rpe: s.rpe) : null;
          if (e != null && (mejor == null || e > mejor!)) mejor = e;
          return liston;
        }(),
    ];
  }

  /// Peso a usar para lograr [targetReps] manteniendo el mismo 1RM estimado.
  /// Útil para sugerir la carga del día a partir del récord.
  static double? weightForReps(double oneRm, int targetReps) {
    if (oneRm <= 0 || targetReps < 1 || targetReps > maxReliableReps) {
      return null;
    }
    return oneRm / (1 + targetReps / 30.0);
  }

  /// Al revés que [weightForReps]: las reps que salen con [weightKg] al mismo
  /// esfuerzo que [refKg] × [refReps]. Si la semana pasada hiciste 50 × 10 y
  /// hoy pones 55, no te va a salir 10: propone 6. Null si la referencia no
  /// da para estimar (más de [maxReliableReps], o sin peso).
  ///
  /// Con esfuerzo: la referencia cuenta con su [refRpe] y se deja en la
  /// recámara lo que pida [rpe] (sin [rpe], lo mismo que la referencia). Si
  /// fue 50 × 10 a RIR 2, a 50 kg y RIR 0 salen 12.
  static int? repsForWeight({
    required double refKg,
    required int refReps,
    required double weightKg,
    double? refRpe,
    double? rpe,
  }) {
    final oneRm = estimate(refKg, refReps, rpe: refRpe);
    if (oneRm == null || weightKg <= 0) return null;
    final objetivo = rpe ?? refRpe;
    if (weightKg == refKg && rir(objetivo) == rir(refRpe)) return refReps;
    final reps = (30 * (oneRm / weightKg - 1) - rir(objetivo)).round();
    return reps.clamp(1, maxReliableReps);
  }
}

/// Volumen de entrenamiento: kilos totales movidos.
class TrainingVolume {
  const TrainingVolume._();

  /// peso × repeticiones. El calentamiento no cuenta, igual que en el trigger
  /// `recalc_workout_totals` del servidor: los dos deben dar el mismo número.
  ///
  /// [lados]: 2 en un unilateral apuntado por lado (las reps son de cada
  /// lado y se mueven los dos). Ver `ModoPeso`. [repsOtroLado]: las del otro
  /// lado si no son las mismas que [reps]; null, las mismas.
  static double forSet({
    double? weightKg,
    int? reps,
    int lados = 1,
    int? repsOtroLado,
  }) {
    if (weightKg == null || reps == null) return 0;
    if (lados == 2) return weightKg * (reps + (repsOtroLado ?? reps));
    return weightKg * reps * lados;
  }
}

/// Redondeo al incremento de disco más cercano, para sugerir cargas reales.
/// En un gimnasio normal el salto mínimo es 2,5 kg (2 discos de 1,25).
double roundToPlate(double kg, {double step = 2.5}) {
  if (step <= 0) return kg;
  return (kg / step).round() * step;
}

/// Nivel de fuerza relativo al peso corporal.
///
/// Los umbrales son múltiplos del peso corporal para el 1RM estimado, en la
/// línea de los estándares públicos tipo Strength Level. No pretenden ser un
/// ranking científico: sirven para decir "vas por aquí" con cuatro básicos
/// del catálogo. Sin sexo o sin peso corporal no se calcula.
enum StrengthBand { untrained, beginner, novice, intermediate, advanced, elite }

extension StrengthBandLabel on StrengthBand {
  String get labelEs => switch (this) {
    StrengthBand.untrained => 'Sin clasificar',
    StrengthBand.beginner => 'Principiante',
    StrengthBand.novice => 'Novato',
    StrengthBand.intermediate => 'Intermedio',
    StrengthBand.advanced => 'Avanzado',
    StrengthBand.elite => 'Élite',
  };
}

enum BiologicalSex { male, female }

class LiftStandard {
  const LiftStandard({
    required this.catalogName,
    required this.maleRatios,
    required this.femaleRatios,
  });

  /// Nombre exacto del catálogo: el histórico agrupa por LOWER(exercise_name).
  final String catalogName;

  /// Umbrales de 1RM / peso corporal: principiante, novato, intermedio,
  /// avanzado, élite.
  final List<double> maleRatios;
  final List<double> femaleRatios;

  List<double> ratiosFor(BiologicalSex sex) =>
      sex == BiologicalSex.male ? maleRatios : femaleRatios;
}

class LiftLevel {
  const LiftLevel({
    required this.catalogName,
    required this.estimated1rm,
    required this.ratio,
    required this.band,
    required this.score,
  });

  final String catalogName;
  final double estimated1rm;
  final double ratio;
  final StrengthBand band;

  /// 0 = por debajo de principiante, 5 = élite o por encima.
  final double score;
}

class AthleteStrengthLevel {
  const AthleteStrengthLevel({
    required this.overall,
    required this.score,
    required this.lifts,
  });

  final StrengthBand overall;
  final double score;
  final List<LiftLevel> lifts;
}

class StrengthLevel {
  const StrengthLevel._();

  /// Los cuatro básicos con los que se pinta el nivel. Los nombres tienen que
  /// coincidir con `globalCatalog` / `seed.sql`.
  static const lifts = <LiftStandard>[
    LiftStandard(
      catalogName: 'Sentadilla trasera',
      maleRatios: [0.75, 1.25, 1.75, 2.25, 2.75],
      femaleRatios: [0.50, 0.90, 1.35, 1.80, 2.30],
    ),
    LiftStandard(
      catalogName: 'Press banca',
      maleRatios: [0.50, 0.90, 1.25, 1.75, 2.20],
      femaleRatios: [0.25, 0.50, 0.80, 1.15, 1.50],
    ),
    LiftStandard(
      catalogName: 'Peso muerto convencional',
      maleRatios: [1.00, 1.50, 2.00, 2.50, 3.00],
      femaleRatios: [0.70, 1.15, 1.60, 2.10, 2.60],
    ),
    LiftStandard(
      catalogName: 'Press militar de pie',
      maleRatios: [0.35, 0.55, 0.80, 1.10, 1.40],
      femaleRatios: [0.20, 0.35, 0.50, 0.75, 1.00],
    ),
  ];

  static BiologicalSex? parseSex(String? raw) {
    return switch (raw) {
      'male' => BiologicalSex.male,
      'female' => BiologicalSex.female,
      _ => null,
    };
  }

  /// [records] se indexa por `LOWER(exercise_name)`.
  static AthleteStrengthLevel? evaluate({
    required String? sex,
    required double? bodyweightKg,
    required Map<String, double> records,
  }) {
    final parsedSex = parseSex(sex);
    if (parsedSex == null || bodyweightKg == null || bodyweightKg <= 0) {
      return null;
    }

    final liftsFound = <LiftLevel>[];
    for (final standard in lifts) {
      final e1rm = records[standard.catalogName.toLowerCase()];
      if (e1rm == null || e1rm <= 0) continue;
      final ratio = e1rm / bodyweightKg;
      final thresholds = standard.ratiosFor(parsedSex);
      liftsFound.add(
        LiftLevel(
          catalogName: standard.catalogName,
          estimated1rm: e1rm,
          ratio: ratio,
          band: _bandFor(ratio, thresholds),
          score: _scoreFor(ratio, thresholds),
        ),
      );
    }
    if (liftsFound.isEmpty) return null;

    final score =
        liftsFound.map((l) => l.score).reduce((a, b) => a + b) /
        liftsFound.length;
    return AthleteStrengthLevel(
      overall: _bandFromScore(score),
      score: score,
      lifts: liftsFound,
    );
  }

  static StrengthBand _bandFor(double ratio, List<double> t) {
    if (ratio < t[0]) return StrengthBand.untrained;
    if (ratio < t[1]) return StrengthBand.beginner;
    if (ratio < t[2]) return StrengthBand.novice;
    if (ratio < t[3]) return StrengthBand.intermediate;
    if (ratio < t[4]) return StrengthBand.advanced;
    return StrengthBand.elite;
  }

  static double _scoreFor(double ratio, List<double> t) {
    if (ratio < t[0]) return (ratio / t[0]).clamp(0, 1) * 0.99;
    for (var i = 0; i < t.length - 1; i++) {
      if (ratio < t[i + 1]) {
        final span = t[i + 1] - t[i];
        final p = span == 0 ? 0.0 : (ratio - t[i]) / span;
        return (i + 1) + p;
      }
    }
    return 5;
  }

  static StrengthBand _bandFromScore(double score) {
    if (score < 1) return StrengthBand.untrained;
    if (score < 2) return StrengthBand.beginner;
    if (score < 3) return StrengthBand.novice;
    if (score < 4) return StrengthBand.intermediate;
    if (score < 5) return StrengthBand.advanced;
    return StrengthBand.elite;
  }
}
