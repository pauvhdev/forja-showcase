// Cliente de Gemini. Vive SOLO aquí: la clave nunca viaja en la app.
//
// Se configura con dos secretos de Supabase:
//   supabase secrets set GEMINI_API_KEY=...
//   supabase secrets set GEMINI_MODEL=gemini-3.6-flash   (opcional)
//
// El modelo va en una variable a propósito. Los nombres de modelo de Google
// caducan, y cuando pase no hay que tocar código ni volver a desplegar.
//
// Y caducan de verdad: el 23/09/2026 `gemini-2.0-flash` dejó de servirse y las
// tres funciones empezaron a devolver 502 con un 404 de Google debajo. Si
// vuelve a pasar, el mensaje de error dice el modelo nuevo; se cambia el
// secreto y listo, sin desplegar.

const ENDPOINT = 'https://generativelanguage.googleapis.com/v1beta/models';

export interface Parte {
  text?: string;
  fileData?: { fileUri: string; mimeType?: string };
  /// Cuántos fotogramas por segundo mira Gemini. Por defecto es 1.
  videoMetadata?: { fps?: number };
}

export class ErrorGemini extends Error {
  constructor(
    message: string,
    readonly status: number,
    /// Lo que respondió Google. No se le enseña al usuario: va al cuerpo de la
    /// respuesta en un campo aparte y a los logs de la función.
    readonly detalle?: string,
  ) {
    super(message);
  }
}

/// Traduce el fallo de Google a algo que el usuario pueda entender y usar.
///
/// El 429 y el 503 son lo mismo desde el móvil: Google está saturado y hay que
/// esperar. Lo que NO puede pasar es lo de hoy, que un modelo retirado llegara
/// a la pantalla como un volcado de JSON con llaves.
function fallo(status: number, cuerpo: string): ErrorGemini {
  if (status === 429 || status === 503) {
    return new ErrorGemini(
      'Gemini está saturado ahora mismo. Prueba en un rato.',
      429,
      cuerpo.slice(0, 500),
    );
  }
  // El detalle sí queda en los logs de la función: `supabase functions logs`.
  console.error(`Gemini respondió ${status}: ${cuerpo}`);
  return new ErrorGemini(
    'La IA no está disponible ahora mismo. Si sigue pasando, avisa.',
    502,
    cuerpo.slice(0, 500),
  );
}

/// Esperas entre reintentos cuando Google dice que está saturado.
///
/// Ese 503 llega rápido: Google rechaza la petición ANTES de ponerse a procesar
/// el vídeo, no después. Así que reintentar cuesta unos segundos, no un minuto,
/// y no gasta cupo extra porque el cupo se cobra una vez al entrar en la
/// función, no por llamada a Gemini.
const ESPERAS_MS = [4000, 10000];

/// Modelo de reserva, para cuando el principal sigue saturado tras reintentar.
///
/// Sale del diagnóstico del 23/09/2026: los 503 son de capacidad de Google y
/// van por modelo, no por el tamaño del vídeo (gemini-flash-latest falló con un
/// Short de un minuto y acertó con uno de veinticinco). flash-lite acertó con
/// los dos, en menos de cuatro segundos y listando bien los ejercicios.
///
/// Es un alias "-latest" a propósito: los nombres concretos caducan, y la
/// reserva es justo lo que no se quiere tener que vigilar. Se cambia con el
/// secreto GEMINI_MODEL_RESERVA, sin desplegar.
const RESERVA_POR_DEFECTO = 'gemini-flash-lite-latest';

/// Lo que devuelve Gemini y qué modelo lo ha dicho. El modelo viaja en la
/// respuesta de la función: si un día contesta la reserva, se ve.
export interface Generado {
  texto: string;
  modelo: string;
}

type Intento = Generado | { status: number; cuerpo: string };

/// Llama a un modelo, reintentando solo si Google dice que está saturado.
async function conReintentos(
  modelo: string,
  key: string,
  cuerpo: Record<string, unknown>,
  esperas: number[],
): Promise<Intento> {
  const url = `${ENDPOINT}/${modelo}:generateContent?key=${key}`;
  let ultimo = { status: 0, cuerpo: '' };

  for (let intento = 0; intento <= esperas.length; intento++) {
    if (intento > 0) {
      await new Promise((listo) => setTimeout(listo, esperas[intento - 1]));
    }

    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(cuerpo),
    });

    if (res.ok) {
      const data = await res.json();
      const texto = data?.candidates?.[0]?.content?.parts
        ?.map((p: { text?: string }) => p.text ?? '')
        .join('') ?? '';
      return { texto, modelo };
    }

    ultimo = { status: res.status, cuerpo: await res.text().catch(() => '') };

    // Lo demás (un modelo retirado, una clave mala) no mejora por insistir.
    if (res.status !== 503 && res.status !== 429) break;
    console.warn(`${modelo}: ${res.status}, reintento ${intento + 1} de ${esperas.length}`);
  }
  return ultimo;
}

const saturado = (status: number) => status === 503 || status === 429;

/// La única llamada a Gemini.
///
/// Todo pasa por aquí para que el reintento, la reserva y el trato de errores
/// sean los mismos para el chat y para las rutinas.
async function generar(cuerpo: Record<string, unknown>): Promise<Generado> {
  const key = Deno.env.get('GEMINI_API_KEY');
  if (!key) {
    throw new ErrorGemini('El servidor no tiene configurada la clave de Gemini.', 503);
  }
  const principal = Deno.env.get('GEMINI_MODEL') ?? 'gemini-3.6-flash';
  const reserva = Deno.env.get('GEMINI_MODEL_RESERVA') ?? RESERVA_POR_DEFECTO;

  let resultado = await conReintentos(principal, key, cuerpo, ESPERAS_MS);
  if ('texto' in resultado) return resultado;

  // Solo se cambia de modelo cuando el problema es de capacidad. Si el
  // principal falla por otra cosa —retirado, petición mala—, la reserva no lo
  // arregla y solo esconde el fallo de verdad.
  if (saturado(resultado.status) && reserva && reserva !== principal) {
    console.warn(`${principal} sigue saturado; se prueba con ${reserva}`);
    resultado = await conReintentos(reserva, key, cuerpo, [ESPERAS_MS[0]]);
    if ('texto' in resultado) return resultado;
  }

  throw fallo(resultado.status, resultado.cuerpo);
}

/// Cuántos tokens pesaría una petición, sin generar nada. Null si no se sabe.
///
/// Es barato y rápido, y sirve para decidir antes de gastar: por ejemplo, a
/// qué ritmo mirar un vídeo. Sin reintentos a propósito: si falla, quien
/// pregunta decide con un valor por defecto en vez de esperar.
export async function contarTokens(partes: Parte[]): Promise<number | null> {
  const key = Deno.env.get('GEMINI_API_KEY');
  if (!key) return null;
  const modelo = Deno.env.get('GEMINI_MODEL') ?? 'gemini-3.6-flash';
  try {
    const res = await fetch(`${ENDPOINT}/${modelo}:countTokens?key=${key}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ contents: [{ role: 'user', parts: partes }] }),
    });
    if (!res.ok) return null;
    const data = await res.json();
    return typeof data?.totalTokens === 'number' ? data.totalTokens : null;
  } catch {
    return null;
  }
}

/// Una llamada a Gemini pidiendo JSON, con el esquema de salida obligado.
///
/// `responseSchema` no es un adorno: sin él, el modelo devuelve markdown, o
/// texto antes del JSON, o cambia los nombres de los campos entre llamadas. Con
/// él, o cumple el contrato o falla — y preferimos que falle.
export async function pedirJson(
  partes: Parte[],
  opciones: {
    instruccion: string;
    esquema: Record<string, unknown>;
    temperatura?: number;
  },
): Promise<{ datos: unknown; modelo: string }> {
  const { texto, modelo } = await generar({
    contents: [{ role: 'user', parts: partes }],
    systemInstruction: { parts: [{ text: opciones.instruccion }] },
    generationConfig: {
      responseMimeType: 'application/json',
      responseSchema: opciones.esquema,
      temperature: opciones.temperatura ?? 0.7,
    },
  });

  if (!texto) {
    throw new ErrorGemini(
      'Gemini no devolvió nada. Suele ser el filtro de seguridad.',
      502,
    );
  }

  try {
    return { datos: JSON.parse(texto), modelo };
  } catch {
    throw new ErrorGemini('Gemini devolvió algo que no es JSON válido.', 502);
  }
}

/// Texto suelto, para el chat. Aquí no hay contrato que imponer.
export async function pedirTexto(
  mensaje: string,
  opciones: {
    instruccion: string;
    historial?: { rol: string; texto: string }[];
    temperatura?: number;
  },
): Promise<Generado> {
  const { texto, modelo } = await generar({
    contents: [
      ...(opciones.historial ?? []).map((m) => ({
        role: m.rol === 'coach' ? 'model' : 'user',
        parts: [{ text: m.texto }],
      })),
      { role: 'user', parts: [{ text: mensaje }] },
    ],
    systemInstruction: { parts: [{ text: opciones.instruccion }] },
    // Holgado a propósito: los modelos 3.x piensan antes de escribir y ese
    // pensamiento sale de este mismo tope. Con 800, el comentarista se
    // quedaba a media frase (27/09/2026). La longitud la marca la instrucción.
    generationConfig: { temperature: opciones.temperatura ?? 0.8, maxOutputTokens: 4096 },
  });

  if (!texto) {
    throw new ErrorGemini('Gemini no contestó. Suele ser el filtro de seguridad.', 502);
  }
  return { texto, modelo };
}
