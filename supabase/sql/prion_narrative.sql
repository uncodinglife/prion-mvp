-- =====================================================================
-- PROYECTO PRION - Banco narrativo de la radioreceptora
-- Tabla 'narrative' + variantes. El motor elegirá una al azar por situación/rol.
-- =====================================================================
-- MAPEO situación -> rama del motor (compute_and_resolve_encounter):
--   detection              -> evento encounter_start (al crearse el encuentro)
--   flee_escape            -> HUIR + MORDER      (civil escapa, -1)
--   flee_caught            -> HUIR + PERSEGUIR   (civil cazado, -2)
--   fight_surprise         -> LUCHAR + PERSEGUIR (civil sorprende, zombie -3)
--   fight_clash_civilwin   -> LUCHAR + MORDER, gana el dado el civil (zombie -4)
--   fight_clash_zombiewin  -> LUCHAR + MORDER, gana el dado el zombie (civil -4)
--   conversion             -> civil a 0 vida (se convierte)
--   neutralization         -> zombie a 0 vida (neutralizado 15 min)
--   game_end_civils        -> cierre, ganan civiles (rol NULL = difusión a todos)
--   game_end_zombies       -> cierre, ganan zombies (rol NULL = difusión a todos)
-- rol: 'civil' | 'zombie' | NULL (difusión). El número de dados, si se quiere
-- mostrar, vive en encounters.dice_roll y se enseña en el overlay, no en la radio.
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.narrative (
  id        BIGSERIAL PRIMARY KEY,
  situation TEXT NOT NULL,
  role      TEXT,                 -- 'civil', 'zombie' o NULL (difusión)
  message   TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS narrative_lookup ON public.narrative (situation, role);

-- Solo lo leen las funciones de servidor (SECURITY DEFINER); el cliente no.
ALTER TABLE public.narrative ENABLE ROW LEVEL SECURITY;

-- (Opcional) vaciar antes de recargar, para reejecutar sin duplicar:
-- TRUNCATE public.narrative RESTART IDENTITY;

-- ---------------------------------------------------------------------
-- DETECCIÓN — civil (central militar filtrada por el cuerpo)
-- ---------------------------------------------------------------------
INSERT INTO public.narrative (situation, role, message) VALUES
('detection','civil','Interferencia en la onda. Algo se mueve a menos de veinticinco metros, y se mueve mal, a tirones. Enciende el radar. Reza por equivocarte.'),
('detection','civil','Señal de proximidad. El vello de la nuca se te eriza un segundo antes del aviso. Tu cuerpo ya lo sabe: te han olido.'),
('detection','civil','Captación cercana. Entre la estática se cuela un arrastre húmedo, una respiración que no es respiración. Está cerca.'),
('detection','civil','Contacto a corta distancia. El aire se ha vuelto denso, eléctrico, como antes de una tormenta. Algo te busca en la oscuridad.'),
('detection','civil','Lectura de movimiento. Lo que viene hacia ti no corre. No le hace falta. Tiene todo el tiempo del mundo, y tú no.'),
('detection','civil','Proximidad confirmada. Enciende el radar y mira bien. Lo que vas a ver no vas a poder olvidarlo.');

-- ---------------------------------------------------------------------
-- DETECCIÓN — zombie (instinto/hambre)
-- ---------------------------------------------------------------------
INSERT INTO public.narrative (situation, role, message) VALUES
('detection','zombie','Carne viva en el radar. Tibia. A menos de veinticinco metros. El hambre te dobla en dos. Ve.'),
('detection','zombie','Late algo cerca. Un corazón asustado, rápido. Lo oyes a través del asfalto, a través de todo. Acércate.'),
('detection','zombie','Olfateas el sudor del vivo antes de verlo. Miedo. Sabe a miedo. El radar solo confirma lo que tu cuerpo ya persigue.'),
('detection','zombie','Señal de presa. Algo respira donde no debería. Cada bocanada suya es una invitación. Caza.'),
('detection','zombie','Proximidad de carne. La onda se llena de su pulso. Tan fuerte. Tan lleno. Tan tuyo.'),
('detection','zombie','Contacto. Hay vida a la vuelta de la sombra, y la vida es lo único que todavía te importa. Búscala.');

-- ---------------------------------------------------------------------
-- FLEE_ESCAPE (HUIR+MORDER) — civil escapa (-1)
-- ---------------------------------------------------------------------
INSERT INTO public.narrative (situation, role, message) VALUES
('flee_escape','civil','La sangre seca del suelo te hace resbalar, pero te impulsas justo cuando esas manos podridas se cierran donde estaba tu cabeza. Vives. (-1)'),
('flee_escape','civil','Corres sin mirar atrás. Sientes su aliento frío en la nuca y luego, de golpe, nada. Solo tu propio jadeo y la oscuridad. (-1)'),
('flee_escape','civil','Un tirón en el brazo, tela que se rasga, piel que arde. Te zafas y la noche te traga antes que a él. Escapaste. (-1)'),
('flee_escape','civil','Tus piernas deciden por ti. Vuelas entre las sombras mientras detrás queda un gruñido de rabia que no te alcanzó. (-1)'),
('flee_escape','civil','Sientes los dedos rozarte la espalda, hambrientos, casi. Casi. Te hundes en lo oscuro y los pierdes. (-1)'),
('flee_escape','civil','El corazón te revienta en la garganta, pero los pies responden. Lo dejas atrás arañando el aire donde estabas. (-1)');

INSERT INTO public.narrative (situation, role, message) VALUES
('flee_escape','zombie','Cierras la mandíbula y solo muerdes aire frío. El calor de la presa se escurre entre tus dedos.'),
('flee_escape','zombie','Un palmo. Te ha faltado un palmo de carne viva. El vivo se hunde en la sombra y el hambre se queda, intacta, royéndote.'),
('flee_escape','zombie','Tus uñas rozan tela, piel, vida… y se llevan solo un jirón. El resto huye. Aúllas por dentro.'),
('flee_escape','zombie','La presa se escurre como agua. Te quedas con el eco de su pulso y nada que llevarte a la boca.'),
('flee_escape','zombie','Muerdes la noche. La carne ya no está, pero su miedo todavía flota en el aire. Lo seguirás.'),
('flee_escape','zombie','Tan cerca que sentías su pánico. Y se ha ido. La onda se vacía. El hambre no.');

-- ---------------------------------------------------------------------
-- FLEE_CAUGHT (HUIR+PERSEGUIR) — civil cazado al huir (-2)
-- ---------------------------------------------------------------------
INSERT INTO public.narrative (situation, role, message) VALUES
('flee_caught','civil','Corres, pero él corre dentro de ti, en tus pesadillas, más rápido. Te alcanza antes de la esquina y algo se rompe. (-2)'),
('flee_caught','civil','Crees que escapas hasta que un peso frío se te echa encima y unos dientes encuentran carne. Te arrancas y sigues, sangrando. (-2)'),
('flee_caught','civil','La huida dura tres pasos. Al cuarto, sus manos. Al quinto, el dolor. Logras soltarte, pero te has dejado un trozo atrás. (-2)'),
('flee_caught','civil','No mira dónde pisa, no le importa caer: solo quiere tu carne. Te embiste y te marca antes de que te zafes. (-2)'),
('flee_caught','civil','Sientes cómo la distancia se cierra, metro a metro, como una trampa que se traga su propia cuerda. Cuando llega, llega entero. (-2)'),
('flee_caught','civil','Pensabas que eras rápido. Él no se cansa, no duda, no teme. Te cae encima y te muerde el avance. (-2)');

INSERT INTO public.narrative (situation, role, message) VALUES
('flee_caught','zombie','No corres: cazas. La distancia se rinde ante ti y tus manos encuentran por fin la carne tibia que late. (civil -2)'),
('flee_caught','zombie','El vivo cree que la velocidad lo salva. No sabe que tú ya no conoces el cansancio. Lo alcanzas. Lo marcas. (civil -2)'),
('flee_caught','zombie','Cada zancada suya es un latido más fuerte en tus oídos. Lo derribas, hincas, y arrancas un pedazo antes de que se zafe. (civil -2)'),
('flee_caught','zombie','Lo persigues hasta el lugar donde el miedo le falla a las piernas. Ahí lo tienes. Ahí lo muerdes. (civil -2)'),
('flee_caught','zombie','No hay rincón oscuro que te lo esconda. Lo hueles, lo alcanzas, lo abres. Se escapa, pero se deja algo entre tus dientes. (civil -2)'),
('flee_caught','zombie','El vivo era veloz. El hambre lo es más. Caes sobre él y le robas un trozo de vida. (civil -2)');

-- ---------------------------------------------------------------------
-- FIGHT_SURPRISE (LUCHAR+PERSEGUIR) — civil sorprende al zombie (zombie -3)
-- ---------------------------------------------------------------------
INSERT INTO public.narrative (situation, role, message) VALUES
('fight_surprise','civil','Esperabas correr, pero algo dentro de ti dice basta. Cuando se lanza, ya no estás donde apunta: giras y golpeas con todo. Retrocede aullando. (zombie -3)'),
('fight_surprise','civil','Tu miedo se convierte en otra cosa, algo afilado. Aprovechas su embestida ciega y lo estrellas contra la oscuridad. (zombie -3)'),
('fight_surprise','civil','Viene a por ti sin pensar, todo hambre y nada de cabeza. Tú sí piensas. Esquivas, cargas y le abres una herida que no esperaba. (zombie -3)'),
('fight_surprise','civil','La adrenalina te vuelve animal a ti también. Lo recibes con un golpe seco que lo dobla. Por un instante, el cazador eres tú. (zombie -3)'),
('fight_surprise','civil','Su furia es su debilidad. Te apartas medio palmo, justo lo necesario, y descargas todo tu pánico convertido en fuerza. Cae herido. (zombie -3)'),
('fight_surprise','civil','No huyes. Te plantas. Y cuando esa cosa se abalanza, encuentra unas manos vivas que todavía saben pelear. Lo hieres y retrocede. (zombie -3)');

INSERT INTO public.narrative (situation, role, message) VALUES
('fight_surprise','zombie','Te lanzas seguro de la carne fácil y te recibe un golpe que no estaba en tus cálculos. El dolor te arranca el hambre por un segundo. (-3)'),
('fight_surprise','zombie','La presa no corre: se queda. Demasiado tarde entiendes por qué. Su golpe te dobla y retrocedes, herido. (-3)'),
('fight_surprise','zombie','Cargas a ciegas, sin miedo, sin pensar. Por eso no ves venir el impacto que te abre y te echa atrás. (-3)'),
('fight_surprise','zombie','Creías tener la cena servida. La cena te ha partido algo por dentro. Te repliegas a las sombras, goteando. (-3)'),
('fight_surprise','zombie','Vas entero a por él y él va entero a por ti. Pierdes. Algo cede dentro de ti con un crujido húmedo. (-3)'),
('fight_surprise','zombie','El vivo todavía tiene fuego. Lo descubres tarde, cuando su golpe te recuerda lo que es el dolor. (-3)');

-- ---------------------------------------------------------------------
-- FIGHT_CLASH_CIVILWIN (LUCHAR+MORDER, dado lo gana el civil) — zombie -4
-- ---------------------------------------------------------------------
INSERT INTO public.narrative (situation, role, message) VALUES
('fight_clash_civilwin','civil','Os encontráis de frente, dos voluntades y una sola sobrevive entera. Esta vez, la tuya. Lo derribas con un crujido que retumba en el silencio. (zombie -4)'),
('fight_clash_civilwin','civil','Cuerpo contra cuerpo, sin trucos, todo a una. Su fuerza muerta contra tu desesperación viva, y gana la vida. Lo abres y cae. (zombie -4)'),
('fight_clash_civilwin','civil','El mundo se reduce a sus dientes y a tus manos. Empujas cuando todo dice ríndete, y algo en él se quiebra. (zombie -4)'),
('fight_clash_civilwin','civil','Forcejeo brutal, manos en la garganta, su frío contra tu fiebre. Apuras la última gota de fuerza y lo vences. (zombie -4)'),
('fight_clash_civilwin','civil','No sabes de dónde sacas el impulso. Solo sabes que cuando todo termina, tú sigues de pie y él no. (zombie -4)'),
('fight_clash_civilwin','civil','Choque salvaje en la oscuridad. Por un instante eterno no hay ganador. Luego lo hay, y eres tú. (zombie -4)');

INSERT INTO public.narrative (situation, role, message) VALUES
('fight_clash_civilwin','zombie','Os trabáis cuerpo a cuerpo, frío contra fiebre, y por una vez la fiebre vence. Algo se parte dentro de ti y el suelo sube a recibirte. (-4)'),
('fight_clash_civilwin','zombie','Tenías la carne entre las manos. Tenías. El vivo pelea como solo pelea quien no quiere morir, y te destroza. (-4)'),
('fight_clash_civilwin','zombie','Forcejeo a vida o muerte, y descubres que todavía puedes perder. Su golpe final te apaga medio cuerpo. (-4)'),
('fight_clash_civilwin','zombie','La presa se defiende con una furia que no entiendes, que ya olvidaste. Te quiebra y caes hacia la sombra. (-4)'),
('fight_clash_civilwin','zombie','Ibas a devorar y te devuelven el hambre multiplicada en dolor. Algo crujió. Era tuyo. (-4)'),
('fight_clash_civilwin','zombie','El choque os funde un instante en una sola masa de violencia. Cuando se separa, tú eres el que sangra negro. (-4)');

-- ---------------------------------------------------------------------
-- FIGHT_CLASH_ZOMBIEWIN (LUCHAR+MORDER, dado lo gana el zombie) — civil -4
-- ---------------------------------------------------------------------
INSERT INTO public.narrative (situation, role, message) VALUES
('fight_clash_zombiewin','civil','Os trabáis en la oscuridad y descubres, demasiado tarde, que la fuerza muerta no se cansa. Sus dientes encuentran su sitio. Algo tuyo se apaga. (-4)'),
('fight_clash_zombiewin','civil','Peleas con todo lo que eres, y no basta. El frío te gana terreno, centímetro a centímetro, hasta morderte hondo. (-4)'),
('fight_clash_zombiewin','civil','Cuerpo a cuerpo, y por un momento crees que ganas. Luego sientes el desgarro y entiendes que no. (-4)'),
('fight_clash_zombiewin','civil','Su hambre es más antigua que tu miedo. Te vence en el forcejeo y te arranca un pedazo de vida. (-4)'),
('fight_clash_zombiewin','civil','Das todo lo que tienes contra algo que ya no siente nada. Pierdes. El dolor te dobla y la sangre te empapa. (-4)'),
('fight_clash_zombiewin','civil','El choque te enseña la peor lección: que querer vivir, a veces, no alcanza. Caes herido, muy herido. (-4)');

INSERT INTO public.narrative (situation, role, message) VALUES
('fight_clash_zombiewin','zombie','Os fundís en un solo nudo de violencia y, esta vez, el hambre puede más. Hincas los dientes donde late la vida y bebes. (civil -4)'),
('fight_clash_zombiewin','zombie','El vivo pelea, grita, suplica con el cuerpo. Da igual. Lo doblas y le arrancas un trozo de lo que le queda. (civil -4)'),
('fight_clash_zombiewin','zombie','Su calor se resiste, pero el frío siempre gana al final. Lo vences y la carne cede entre tus dientes. (civil -4)'),
('fight_clash_zombiewin','zombie','Forcejeo brutal, y descubres que todavía recuerdas cómo se mata. Lo dejas tirado, abierto, vaciándose. (civil -4)'),
('fight_clash_zombiewin','zombie','Toda su furia viva contra tu hambre muerta. Gana el hambre. Siempre el hambre. Te llevas tu pedazo. (civil -4)'),
('fight_clash_zombiewin','zombie','Lo aprietas hasta que algo en él se rinde. Entonces muerdes. El sabor de la vida ajena te recorre entero. (civil -4)');

-- ---------------------------------------------------------------------
-- CONVERSIÓN — civil que cae a 0 y se transforma (tu propia voz apagándose)
-- ---------------------------------------------------------------------
INSERT INTO public.narrative (situation, role, message) VALUES
('conversion','civil','La fiebre sube como una marea. Las luces duelen, los sonidos se alargan. Tu último pensamiento con tu propia voz es que ya no la reconoces. Bienvenido a la horda.'),
('conversion','civil','Primero el frío. Luego un calor que no es tuyo. Luego un hambre sin fondo que se come tu nombre, tus recuerdos, tu miedo. Solo queda buscar carne.'),
('conversion','civil','Intentas recordar quién eras y la respuesta se disuelve, letra a letra, como una emisora que pierde la señal. Lo último que oyes es tu propio gruñido.'),
('conversion','civil','El dolor cesa, y eso es lo peor. En su lugar queda un vacío que solo se llena de una manera. Ahora lo sabes. Ahora eres uno de ellos.'),
('conversion','civil','Sientes cómo algo se apaga detrás de tus ojos, una luz tras otra. Cuando se apaga la última, ya no tienes miedo. Tienes hambre.'),
('conversion','civil','Tu corazón da un último golpe humano y luego encuentra otro ritmo, más lento, más antiguo, más hambriento. La ciudad acaba de ganar un cazador.');

-- ---------------------------------------------------------------------
-- NEUTRALIZACIÓN — zombie derribado 15 min (caer sin morir del todo)
-- ---------------------------------------------------------------------
INSERT INTO public.narrative (situation, role, message) VALUES
('neutralization','zombie','Un golpe final y el mundo se inclina. Caes sin caer del todo, atrapado entre el hambre y la nada. Quince minutos de oscuridad inerte.'),
('neutralization','zombie','Tu cuerpo deja de obedecer. Lo ves todo desde muy lejos, como bajo el agua. Estás abajo. Tardarás en volver.'),
('neutralization','zombie','La horda no muere. Pero por un rato, tú tampoco te mueves. Te derriban y la quietud te sepulta. El hambre tendrá que esperar.'),
('neutralization','zombie','Se apagan tus sentidos uno a uno. No es el final, es una pausa, pero se siente como morir otra vez. Quince minutos a oscuras.'),
('neutralization','zombie','Caes inerte sobre el suelo frío. Los demás te ven, te rodean, te dejan atrás. Volverás. Siempre se vuelve.'),
('neutralization','zombie','Algo te tumba y el radar enmudece. Estás ahí, visible, indefenso, mientras la ciudad sigue cazando sin ti. Por ahora.');

-- ---------------------------------------------------------------------
-- FIN DE PARTIDA — ganan civiles (difusión, rol NULL)
-- ---------------------------------------------------------------------
INSERT INTO public.narrative (situation, role, message) VALUES
('game_end_civils',NULL,'A todas las unidades: amanece. Los focos de infección quedan contenidos. Hay supervivientes en la zona. Repito: hay supervivientes. La ciudad respira. Corten transmisión.'),
('game_end_civils',NULL,'Última lectura de la onda: pulsos humanos confirmados, suficientes para resistir. Lo imposible ha ocurrido. Aguantasteis. Esto es el final de la emisión.'),
('game_end_civils',NULL,'Cierre de protocolo. La noche ha terminado y todavía late gente bajo estos tejados. Recordad lo que visteis. Nadie os creerá. Corto.'),
('game_end_civils',NULL,'La horda no ha vencido. Que conste en el registro: en Sant Feliu, esta vez, ganaron los vivos. Fin de la transmisión.');

-- ---------------------------------------------------------------------
-- FIN DE PARTIDA — ganan zombies (difusión, rol NULL)
-- ---------------------------------------------------------------------
INSERT INTO public.narrative (situation, role, message) VALUES
('game_end_zombies',NULL,'A cualquier unidad que aún escuche… la onda está muda. No quedan pulsos humanos en la zona. No queda nadie que responda. La ciudad es suya. Corten—'),
('game_end_zombies',NULL,'Última lectura: silencio. Donde había miedo, ahora solo hay hambre que camina. La infección es total. Que Dios se apiade de quien venga después.'),
('game_end_zombies',NULL,'Cierre forzoso de protocolo. Hemos perdido la zona. Hemos perdido a todos. Si alguien oye esto, no vengáis. Huid. Corto y cier—'),
('game_end_zombies',NULL,'Que conste en el registro: la noche ganó. Sant Feliu ha caído. No queda voz viva en esta frecuencia. Fin de la trans—');