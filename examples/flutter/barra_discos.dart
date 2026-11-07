import 'package:flutter/material.dart';

import '../../core/discos.dart';
import '../../design/tokens.dart';

/// El color de cada disco, el de competición: rojo 25, azul 20, amarillo 15,
/// verde 10, blanco 5; los pequeños, rojo oscuro y cromado.
Color colorDisco(double kg) => switch (kg) {
  25 => const Color(0xFFD83A34),
  20 => const Color(0xFF2563C9),
  15 => const Color(0xFFE9B82B),
  10 => const Color(0xFF2E9A51),
  5 => const Color(0xFFE8E8EC),
  2.5 => const Color(0xFF9E2A26),
  _ => const Color(0xFFA9ADB6),
};

/// Alto y grosor de cada disco, en proporción al de 25 (el más grande).
({double alto, double grosor}) _forma(double kg) => switch (kg) {
  25 || 20 => (alto: 1.0, grosor: 1.0),
  15 => (alto: .86, grosor: .8),
  10 => (alto: .72, grosor: .62),
  5 => (alto: .52, grosor: .5),
  2.5 => (alto: .42, grosor: .4),
  _ => (alto: .34, grosor: .34),
};

String _kg(double v) => v == v.roundToDouble()
    ? v.toStringAsFixed(0)
    : v.toStringAsFixed(2).replaceAll(RegExp(r'0$'), '').replaceAll('.', ',');

/// La barra con sus discos, dibujada, y debajo lo que va en cada lado.
class BarraConDiscos extends StatelessWidget {
  const BarraConDiscos({required this.carga, super.key});

  final CargaBarra carga;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final lado = carga.porLado;

    return Semantics(
      label: lado.isEmpty
          ? 'Barra sola'
          : 'Por lado: ${lado.map(_kg).join(' más ')} kilos',
      child: Column(
        children: [
          SizedBox(
            height: 64,
            width: double.infinity,
            child: CustomPaint(
              painter: _PintorBarra(
                porLado: lado,
                barra: theme.colorScheme.onSurfaceVariant,
                borde: theme.colorScheme.surface,
              ),
            ),
          ),
          const SizedBox(height: Gap.xs),
          if (lado.isEmpty)
            Text(
              'Barra sola (${_kg(carga.barraKg)} kg)',
              style: TextStyle(color: muted, fontSize: 13),
            )
          else
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              runSpacing: 4,
              children: [
                Text('Por lado ', style: TextStyle(color: muted, fontSize: 13)),
                for (final d in lado) _Pastilla(kg: d),
                Text(
                  '  · barra ${_kg(carga.barraKg)}',
                  style: TextStyle(color: muted, fontSize: 13),
                ),
              ],
            ),
          if (carga.sobra > 0)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'No cuadra: sobran ${_kg(carga.sobra)} kg con estos discos',
                style: const TextStyle(fontSize: 12, color: ForjaColors.pr),
              ),
            ),
        ],
      ),
    );
  }
}

class _Pastilla extends StatelessWidget {
  const _Pastilla({required this.kg});

  final double kg;

  @override
  Widget build(BuildContext context) {
    final fondo = colorDisco(kg);
    final claro = fondo.computeLuminance() > .5;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: fondo, borderRadius: Radii.brSm),
      child: Text(
        _kg(kg),
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 13,
          fontFeatures: tabularFigures,
          color: claro ? Colors.black : Colors.white,
        ),
      ),
    );
  }
}

class _PintorBarra extends CustomPainter {
  _PintorBarra({
    required this.porLado,
    required this.barra,
    required this.borde,
  });

  final List<double> porLado;
  final Color barra;
  final Color borde;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final altoMax = size.height;
    // El grosor del disco grande, que no se coma la barra con muchos discos.
    final grosor = (size.width * .045).clamp(8.0, 14.0);
    final mitad = size.width / 2;

    final pBarra = Paint()..color = barra;
    // La barra entera, de punta a punta, y los topes (collarines) de dentro.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(mitad, cy),
          width: size.width,
          height: 6,
        ),
        const Radius.circular(3),
      ),
      pBarra,
    );
    final topeX = mitad * .38;
    for (final x in [mitad - topeX, mitad + topeX]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(x, cy), width: 6, height: 22),
          const Radius.circular(2),
        ),
        pBarra,
      );
    }

    // Los discos, del tope hacia fuera, igual a los dos lados.
    final pBorde = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = borde;
    for (final lado in [-1.0, 1.0]) {
      var x = mitad + lado * (topeX + 5);
      for (final d in porLado) {
        final f = _forma(d);
        final w = grosor * f.grosor;
        final h = altoMax * f.alto;
        final rect = Rect.fromLTWH(lado > 0 ? x : x - w, cy - h / 2, w, h);
        final rr = RRect.fromRectAndRadius(rect, const Radius.circular(2.5));
        canvas.drawRRect(rr, Paint()..color = colorDisco(d));
        canvas.drawRRect(rr, pBorde);
        x += lado * (w + 1);
      }
    }
  }

  @override
  bool shouldRepaint(_PintorBarra old) =>
      old.barra != barra ||
      old.borde != borde ||
      old.porLado.length != porLado.length ||
      !Iterable.generate(
        porLado.length,
      ).every((i) => old.porLado[i] == porLado[i]);
}
