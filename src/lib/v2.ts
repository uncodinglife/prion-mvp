// Prion v2: tipos y utilidades compartidas por el alta y la pantalla de juego.
// Toda la lógica vive en el servidor (funciones de supabase/sql/v2); aquí solo
// se llaman las RPC y se traduce su respuesta para la interfaz.
import { supabase } from '$lib/supabase';

export interface MyPlayer {
	id: string;
	nick: string;
	role: 'civil' | 'zombie';
	life: number;
	life_max: number;
	age_band: string | null;
	food_stock: number | null;
	status: string;
	status_until: string | null;
	inside_refuge_id: string | null;
	resting: boolean;
	infected_at: string | null;
	overexcited_until: string | null;
	down_until: string | null;
}

export interface LootState {
	state: 'started' | 'looting' | 'completed' | 'aborted' | 'cooldown';
	poi_id: number;
	remaining_s?: number;
	available_at?: string;
	reward?: { rations?: number; resistance?: number };
}

// Respuesta de report_position para un jugador v2.
export interface PositionReport {
	v2: true;
	role: 'civil' | 'zombie';
	life: number;
	life_max: number;
	food_stock: number;
	inside_refuge: 'home' | 'mixed' | 'hideout' | null;
	entered: boolean;
	exited: boolean;
	signal_loss_seconds: number | null;
	exit_streak: number;
	resting: boolean;
	infected: boolean;
	overexcited_until: string | null;
	down_until: string | null;
	loot: LootState | null;
	status: string;
	status_until: string | null;
	encounter_id: string | null;
}

export type ReportResult = PositionReport | { v2: false };

export const REFUGE_LABELS: Record<string, string> = {
	home: 'en casa',
	mixed: 'en tu zona de trabajo',
	hideout: 'escondido'
};

export const PROFILE_FIELDS: { field: string; label: string }[] = [
	{ field: 'sex', label: 'Sexo' },
	{ field: 'eye_color', label: 'Color de ojos' },
	{ field: 'hair_color', label: 'Pelo' },
	{ field: 'height_band', label: 'Estatura' },
	{ field: 'profession', label: 'Profesión' },
	{ field: 'hobby', label: 'Afición' }
];

export async function fetchMe(): Promise<MyPlayer | null> {
	const {
		data: { user }
	} = await supabase.auth.getUser();
	if (!user) return null;
	const { data, error } = await supabase
		.from('players')
		.select(
			'id, nick, role, life, life_max, age_band, food_stock, status, status_until, inside_refuge_id, resting, infected_at, overexcited_until, down_until'
		)
		.eq('id', user.id)
		.single();
	if (error || !data) return null;
	return data as MyPlayer;
}

export async function reportPosition(
	lat: number,
	lng: number,
	accuracy: number
): Promise<ReportResult> {
	const { data, error } = await supabase.rpc('report_position', {
		p_lat: lat,
		p_lng: lng,
		p_accuracy: accuracy
	});
	if (error) throw error;
	return data as ReportResult;
}

// Llama a una acción del jugador y devuelve el mensaje de error del servidor
// (ya está redactado para el jugador) o null si salió bien.
export async function callAction(
	fn: string,
	args: Record<string, unknown> = {}
): Promise<{ data: any; error: string | null }> {
	const { data, error } = await supabase.rpc(fn, args);
	return { data, error: error ? error.message : null };
}

export function formatRemaining(ms: number): string {
	const totalSeconds = Math.max(0, Math.ceil(ms / 1000));
	const minutes = Math.floor(totalSeconds / 60);
	const seconds = totalSeconds % 60;
	return `${minutes}m ${seconds.toString().padStart(2, '0')}s`;
}
