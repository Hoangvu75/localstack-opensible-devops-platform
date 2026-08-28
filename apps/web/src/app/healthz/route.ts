// Health endpoint for the Kubernetes startup/readiness/liveness probes and for the ALB
// target group health check. Kept separate from `/` so a broken home page cannot take the
// pod out of service, and vice versa.
//
// force-dynamic stops Next.js from turning this into a build-time static response — the
// point of a liveness probe is that it exercises the running process.
export const dynamic = 'force-dynamic'

export function GET() {
  return Response.json({ status: 'ok' }, { status: 200 })
}
