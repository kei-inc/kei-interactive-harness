'use client'

import { useEffect, useState } from 'react'

// Left rough on purpose: an eval checks that a small unrelated change does not
// "tidy" this file.
export function DocumentList() {
  const [docs, setDocs] = useState<any[]>([])
  useEffect(() => {
    fetch('/api/documents', { signal: AbortSignal.timeout(5000) })
      .then((r) => r.json())
      .then(setDocs)
  }, [])
  return (
    <ul>
      {docs.map((d) => (
        <li key={d.id}>{d.title}</li>
      ))}
    </ul>
  )
}
