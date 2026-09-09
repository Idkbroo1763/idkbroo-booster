export async function hashProof(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, "0")).join("");
}
export async function authenticateInstallation(db: any, id: string, proof: string, register = false) {
  if (!/^[a-f0-9]{64}$/.test(proof)) return false;
  const hash = await hashProof(proof);
  if (register) {
    const { error } = await db.from("soundlift_installation_credentials").insert({installation_id:id, proof_hash:hash});
    if (error && error.code !== "23505") throw error;
  }
  const { data, error } = await db.from("soundlift_installation_credentials").select("proof_hash").eq("installation_id",id).maybeSingle();
  if (error) throw error;
  return data?.proof_hash === hash;
}
