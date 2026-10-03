import { fmtDateTime } from "@/lib/format-date";
import { createClient } from "@/lib/supabase/server";
import { Badge, Button, EmptyState, PageTitle, SectionHeader, Table, Td, Th } from "@/components/ui";
import { ConfirmButton } from "@/components/confirm-button";
import { assignDevice, saveDevice, setDeviceState, setDriverFallback, unassignDevice } from "./actions";

/* eslint-disable @typescript-eslint/no-explicit-any */

const inputClass = "w-full rounded-md border border-border bg-surface px-3 py-2 text-sm text-text-primary";

const CONNECTION_LABEL: Record<string, string> = {
  never_connected: "Never connected",
  online: "Online",
  offline: "Offline",
  error: "Error",
};

function fmt(ts?: string | null) {
  return ts ? fmtDateTime(ts) : "—";
}

export default async function GpsDevicesPage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  const { error } = await searchParams;
  const supabase = await createClient();

  const [{ data: list }, { data: events }, { data: buses }] = await Promise.all([
    supabase.rpc("admin_list_gps_devices"),
    supabase.rpc("admin_list_gps_integration_events", { p_limit: 30 }),
    supabase.from("buses").select("id, registration_number, allow_driver_fallback, operators(name)").order("registration_number"),
  ]);
  const devices: any[] = (list as any)?.devices ?? [];
  const recent: any[] = (events as any)?.events ?? [];

  return (
    <div>
      <PageTitle
        title="GPS devices"
        subtitle="Register trackers, connect them to a bus and a provider, and watch their health. No provider is connected until a device is activated and actually sends a location."
      />
      {error && <p className="mb-4 rounded-md border border-error/40 bg-error/10 px-4 py-3 text-sm text-error">{error}</p>}

      <details className="mb-6 rounded-lg border border-border bg-surface p-4">
        <summary className="cursor-pointer text-sm font-medium text-primary">Register a device</summary>
        <form action={saveDevice.bind(null, null)} className="mt-4 grid max-w-3xl grid-cols-2 gap-3">
          <label className="text-sm">Device name<input name="name" className={inputClass} /></label>
          <label className="text-sm">Device identifier *<input name="device_identifier" required className={inputClass} /></label>
          <label className="text-sm">Provider<input name="provider" placeholder="set when a provider is chosen" className={inputClass} /></label>
          <label className="text-sm">Integration type<input name="integration_type" placeholder="e.g. http_push, tcp" className={inputClass} /></label>
          <label className="text-sm">IMEI (15 digits)<input name="imei" pattern="[0-9]{15}" className={inputClass} /></label>
          <label className="text-sm">Serial number<input name="serial_no" className={inputClass} /></label>
          <label className="text-sm">SIM / communication ID<input name="sim_ref" className={inputClass} /></label>
          <label className="text-sm">Installation date<input name="installed_on" type="date" className={inputClass} /></label>
          <label className="col-span-2 text-sm">
            Provider secret name (stored server-side, never the credential itself)
            <input name="provider_config_ref" className={inputClass} />
          </label>
          <label className="col-span-2 text-sm">Notes<textarea name="notes" rows={2} className={inputClass} /></label>
          <div className="col-span-2"><Button type="submit">Save device</Button></div>
        </form>
      </details>

      <Table>
        <thead>
          <tr>
            <Th>Device</Th>
            <Th>Bus / operator</Th>
            <Th>Provider</Th>
            <Th>Status</Th>
            <Th>Last communication</Th>
            <Th>Last known location</Th>
            <Th>Actions</Th>
          </tr>
        </thead>
        <tbody>
          {devices.map((d) => (
            <tr key={d.id}>
              <Td>
                <div className="font-medium">{d.name || d.device_identifier}</div>
                <div className="font-mono text-xs text-text-tertiary">{d.device_identifier}</div>
                {d.imei && <div className="text-xs text-text-tertiary">IMEI {d.imei}</div>}
              </Td>
              <Td>
                {d.bus_registration ? (
                  <>
                    <div>{d.bus_registration}</div>
                    <div className="text-xs text-text-tertiary">{d.operator_name}</div>
                  </>
                ) : (
                  <span className="text-text-tertiary">Unassigned</span>
                )}
              </Td>
              <Td>
                {d.provider ?? <span className="text-text-tertiary">Not set</span>}
                {d.integration_type && <div className="text-xs text-text-tertiary">{d.integration_type}</div>}
              </Td>
              <Td>
                <div className="flex flex-col items-start gap-1">
                  <Badge status={d.activation_status} />
                  <span className="text-xs text-text-secondary">{CONNECTION_LABEL[d.connection_status] ?? d.connection_status}</span>
                  {d.last_error && <span className="max-w-[12rem] text-xs text-error">{d.last_error}</span>}
                </div>
              </Td>
              <Td>{fmt(d.last_communication_at)}</Td>
              <Td>
                {d.last_location ? (
                  <>
                    <div className="font-mono text-xs">{d.last_location.latitude}, {d.last_location.longitude}</div>
                    <div className="text-xs text-text-tertiary">{fmt(d.last_location.recorded_at)}</div>
                  </>
                ) : (
                  "—"
                )}
              </Td>
              <Td>
                <div className="flex min-w-[14rem] flex-col gap-2">
                  <form action={assignDevice.bind(null, d.id)} className="flex gap-1">
                    <select name="bus_id" defaultValue={d.bus_id ?? ""} className={`${inputClass} py-1`}>
                      <option value="">Choose bus…</option>
                      {(buses as any[] | null)?.map((b) => (
                        <option key={b.id} value={b.id}>{b.registration_number} · {b.operators?.name}</option>
                      ))}
                    </select>
                    <Button type="submit" variant="outline" className="px-2 py-1 text-xs">{d.bus_id ? "Reassign" : "Assign"}</Button>
                  </form>
                  <div className="flex flex-wrap gap-1">
                    {d.activation_status !== "active" && (
                      <form action={setDeviceState.bind(null, d.id, "active")}><Button type="submit" className="px-2 py-1 text-xs">Activate</Button></form>
                    )}
                    {d.activation_status === "active" && (
                      <form action={setDeviceState.bind(null, d.id, "inactive")}><ConfirmButton message="Deactivate this device? It will stop being used for tracking." variant="outline" className="px-2 py-1 text-xs">Deactivate</ConfirmButton></form>
                    )}
                    {d.bus_id && (
                      <form action={unassignDevice.bind(null, d.id)}><ConfirmButton message="Disconnect this device from its bus?" variant="outline" className="px-2 py-1 text-xs">Disconnect</ConfirmButton></form>
                    )}
                    {d.activation_status !== "retired" && (
                      <form action={setDeviceState.bind(null, d.id, "retired")}><ConfirmButton message="Retire this device permanently?" variant="destructive" className="px-2 py-1 text-xs">Retire</ConfirmButton></form>
                    )}
                  </div>
                  <details>
                    <summary className="cursor-pointer text-xs text-primary">Edit configuration</summary>
                    <form action={saveDevice.bind(null, d.id)} className="mt-2 grid gap-2">
                      <input name="name" defaultValue={d.name ?? ""} placeholder="Name" className={inputClass} />
                      <input name="provider" defaultValue={d.provider ?? ""} placeholder="Provider" className={inputClass} />
                      <input name="integration_type" defaultValue={d.integration_type ?? ""} placeholder="Integration type" className={inputClass} />
                      <input name="provider_config_ref" defaultValue={d.provider_config_ref ?? ""} placeholder="Provider secret name" className={inputClass} />
                      <input name="imei" defaultValue={d.imei ?? ""} placeholder="IMEI" pattern="[0-9]{15}" className={inputClass} />
                      <input name="serial_no" defaultValue={d.serial_no ?? ""} placeholder="Serial no." className={inputClass} />
                      <input name="sim_ref" defaultValue={d.sim_ref ?? ""} placeholder="SIM ref" className={inputClass} />
                      <textarea name="notes" defaultValue={d.notes ?? ""} rows={2} placeholder="Notes" className={inputClass} />
                      <Button type="submit" variant="outline" className="px-2 py-1 text-xs">Save</Button>
                    </form>
                  </details>
                </div>
              </Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!devices.length && <EmptyState message="No GPS devices have been registered yet." />}

      <div className="mt-8">
        <SectionHeader title="Phone fallback per bus" />
        <p className="mb-3 text-sm text-text-secondary">
          When on, a driver’s phone location may stand in for the tracker if the tracker is silent. It is shown as “Live — Verified Fallback”, never as the tracker.
        </p>
        <Table>
          <thead><tr><Th>Bus</Th><Th>Operator</Th><Th>Fallback</Th><Th></Th></tr></thead>
          <tbody>
            {(buses as any[] | null)?.map((b) => (
              <tr key={b.id}>
                <Td>{b.registration_number}</Td>
                <Td>{b.operators?.name}</Td>
                <Td><Badge status={b.allow_driver_fallback ? "active" : "inactive"} /></Td>
                <Td>
                  <form action={setDriverFallback.bind(null, b.id, !b.allow_driver_fallback)}>
                    <Button type="submit" variant="outline" className="px-2 py-1 text-xs">{b.allow_driver_fallback ? "Turn off" : "Turn on"}</Button>
                  </form>
                </Td>
              </tr>
            ))}
          </tbody>
        </Table>
      </div>

      <div className="mt-8">
        <SectionHeader title="Integration events" />
        <Table>
          <thead><tr><Th>When</Th><Th>Level</Th><Th>Message</Th></tr></thead>
          <tbody>
            {recent.map((e) => (
              <tr key={e.id}>
                <Td>{fmt(e.created_at)}</Td>
                <Td><Badge status={e.level === "error" ? "failed" : e.level === "warning" ? "pending" : "approved"} /></Td>
                <Td>{e.message}</Td>
              </tr>
            ))}
          </tbody>
        </Table>
        {!recent.length && <EmptyState message="No integration events. Errors from a provider or a misbehaving device appear here." />}
      </div>
    </div>
  );
}
