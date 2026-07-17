// Public client config (anon key is safe in the browser with RLS/RPCs).
window.BUDGET_CONFIG = {
  url: 'https://dbwpoxgkstajqsyqhlkh.supabase.co',
  anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRid3BveGdrc3RhanFzeXFobGtoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQwNDM4NDAsImV4cCI6MjA5OTYxOTg0MH0.uJX-AA1Ew4YS6NXi_Hn8OyjveHYWco9JoHuFvfYzVgs',
  // Google Cloud → APIs & Services → Credentials → OAuth 2.0 Client ID (Web).
  // Authorized JavaScript origins must include http://127.0.0.1:8080 (and your deploy origin).
  // Enable the Google Calendar API on the same project.
  googleClientId: ''
};
