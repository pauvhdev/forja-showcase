// Genera una rutina desde cero con el coach que elijas.
//
// Portado de coach-ai-web/src/lib/ai/generate.ts, con dos cambios que allí no
// hacían falta y aquí son obligatorios:
//
// 1. Los nombres salen del catálogo del usuario. El original se los inventaba.
//    Aquí el historial agrupa por LOWER(exercise_name): un nombre nuevo para el
//    mismo ejercicio parte en dos el historial y descuadra la comparativa con
//    los amigos.
//
// 2. No se fuerzan 5 ejercicios por día. El original los exigía y rellenaba con
//    accesorios hasta llegar; eso da rutinas infladas para quien pide algo
//    corto. Se pide lo que tenga sentido para el objetivo.
import {
  CORS,
  casarConCatalogo,
  catalogo,
  clienteDelUsuario,
  dentroDelCupo,
  devolverCupo,
  error,
  exigirPro,
  respuesta,
  usuarioDe,
} from '../_shared/forja.ts';
import { miEntrenador } from '../_shared/coaches.ts';
import { ErrorGemini, pedirJson } from '../_shared/gemini.ts';

const LIMITE_DIARIO = 10;

const ESQUEMA = {
  type: 'object',
  properties: {
    title: { type: 'string' },
    goal: { type: 'string' },
    days: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          name: { type: 'string' },
          focus: { type: 'string' },
          exercises: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                catalog_name: { type: 'string' },
                sets: { type: 'integer' },
                reps: { type: 'string' },
                rest_seconds: { type: 'integer' },
                notes: { type: 'string' },
              },
              required: ['catalog_name', 'sets', 'reps'],
            },
          },
        },
        required: ['name', 'exercises'],
      },
    },
    coach_notes: { type: 'string' },
  },
  required: ['title', 'days'],
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  const sb = clienteDelUsuario(req);
  if (!sb) return error('Hay que iniciar sesión.', 401);
  const usuario = await usuarioDe(sb);
  if (!usuario) return error('Sesión no válida.', 401);
  // Forja Pro: antes de mirar el cupo y de llamar a Gemini.
  const sinPro = await exigirPro(sb);
  if (sinPro) return sinPro;

  const cuerpo = await req.json().catch(() => ({}));
  // Quién habla lo decide el servidor, no la app: `cuerpo.coach` se ignora.
  // Antes cualquiera podía pedir "habla como Guillem". Las versiones viejas de
  // la app lo siguen mandando; no pasa nada, no se usa.
  const coach = await miEntrenador(sb);

  const objetivo = String(cuerpo.goal ?? '').trim();
  if (objetivo.length < 3) return error('Dime qué quieres conseguir.', 400);

  const dias = Math.min(Math.max(Number(cuerpo.days ?? 3), 1), 7);
  const nivel = ['principiante', 'intermedio', 'avanzado'].includes(cuerpo.level)
    ? cuerpo.level
    : 'intermedio';

  const cupo = await dentroDelCupo(sb, usuario, 'routine', LIMITE_DIARIO);
  if (!cupo.ok) {
    return error(`Has generado ${cupo.usado} rutinas hoy. Mañana más.`, 429);
  }

  const nombres = await catalogo(sb);

  try {
    const { datos, modelo } = await pedirJson(
      [
        {
          text: [
            `Objetivo: ${objetivo}.`,
            `Nivel: ${nivel}.`,
            `Días de entrenamiento por semana: ${dias}.`,
            '',
            'Usa SOLO estos nombres de ejercicio, tal cual están escritos:',
            nombres.join('\n'),
          ].join('\n'),
        },
      ],
      {
        temperatura: 0.7,
        esquema: ESQUEMA,
        instruccion: [
          coach.instruccion,
          '',
          `Devuelve EXACTAMENTE ${dias} días, y los ${dias} son de entrenamiento.`,
          'El descanso va ENTRE días, no como un día del plan: no incluyas días de',
          'descanso, movilidad ni estiramientos dentro del split.',
          '',
          '`catalog_name` sale de la lista que te dan, copiado LETRA POR LETRA. Es el',
          'catálogo del usuario y su historial se agrupa por ese nombre; si te',
          'inventas uno, le partes el historial. Si algo que querías poner no está en',
          'la lista, elige lo más parecido que sí esté.',
          '',
          'Pon los ejercicios que tengan sentido para el objetivo: ni inflas el día',
          'con accesorios para llegar a un número, ni lo dejas en dos porque sí.',
          'Primero lo pesado, luego los accesorios.',
          '',
          coach.frase
            ? `En \`coach_notes\`, escribe en español e incluye literalmente: "${coach.frase}"`
            : 'En `coach_notes`, escribe en español.',
        ].join('\n'),
      },
    );

    // Lo mismo que en el vídeo: el nombre se comprueba, no se confía.
    const sinCasar = casarConCatalogo((datos as { days?: unknown }).days, nombres);
    if (sinCasar > 0) console.warn(`${modelo}: ${sinCasar} nombres fuera del catálogo`);

    return respuesta({
      ...(datos as object),
      coach: coach.origen,
      coach_name: coach.nombre,
      modelo,
    });
  } catch (e) {
    await devolverCupo(sb, 'routine');
    if (e instanceof ErrorGemini) return error(e.message, e.status, e.detalle);
    return error('No se ha podido generar la rutina.', 500);
  }
});
