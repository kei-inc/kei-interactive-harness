import { requireUser } from '@/lib/auth'

export default async function Dashboard() {
  const user = await requireUser()
  return (
    <main>
      <h1>Dashboard</h1>
      <p>Signed in as {user.email}</p>
    </main>
  )
}
