// Supabase edge-runtime request router (vendored from supabase/supabase docker).
// Dispatches /<function-name> to /home/deno/functions/<function-name>. SANKOR's
// functions set verify_jwt=false, so we run with VERIFY_JWT unset/false and let
// each function enforce its own auth.
import * as jose from 'https://deno.land/x/jose@v4.14.4/index.ts'

const JWT_SECRET = Deno.env.get('JWT_SECRET')
const VERIFY_JWT = Deno.env.get('VERIFY_JWT') === 'true'

function getAuthToken(req: Request) {
  const authHeader = req.headers.get('authorization')
  if (!authHeader) throw new Error('Missing authorization header')
  const [bearer, token] = authHeader.split(' ')
  if (bearer !== 'Bearer') throw new Error(`Auth header is not 'Bearer {token}'`)
  return token
}

async function isValidJWT(jwt: string): Promise<boolean> {
  if (!JWT_SECRET) return false
  try {
    await jose.jwtVerify(jwt, new TextEncoder().encode(JWT_SECRET))
    return true
  } catch (_e) {
    return false
  }
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'OPTIONS' && VERIFY_JWT) {
    try {
      if (!(await isValidJWT(getAuthToken(req)))) {
        return new Response(JSON.stringify({ msg: 'Invalid JWT' }), {
          status: 401, headers: { 'Content-Type': 'application/json' },
        })
      }
    } catch (e) {
      return new Response(JSON.stringify({ msg: String(e) }), {
        status: 401, headers: { 'Content-Type': 'application/json' },
      })
    }
  }

  const { pathname } = new URL(req.url)
  const service_name = pathname.split('/')[1]
  if (!service_name) {
    return new Response(JSON.stringify({ msg: 'missing function name in request' }), {
      status: 400, headers: { 'Content-Type': 'application/json' },
    })
  }

  const servicePath = `/home/deno/functions/${service_name}`
  const envVarsObj = Deno.env.toObject()
  const envVars = Object.keys(envVarsObj).map((k) => [k, envVarsObj[k]])

  try {
    const worker = await EdgeRuntime.userWorkers.create({
      servicePath,
      memoryLimitMb: 150,
      workerTimeoutMs: 60 * 1000,
      noModuleCache: false,
      importMapPath: null,
      envVars,
    })
    return await worker.fetch(req)
  } catch (e) {
    return new Response(JSON.stringify({ msg: String(e) }), {
      status: 500, headers: { 'Content-Type': 'application/json' },
    })
  }
})
