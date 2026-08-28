import './globals.css'
import type { Metadata } from 'next'

export const metadata: Metadata = {
  title: 'DevOps Learning Web App ✨',
  description: 'This website is created for learning DevOps with OpenSible & Floci EKS',
}

export default function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  )
}
