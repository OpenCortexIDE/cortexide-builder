'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { api, ApiError } from '@/lib/api';

export default function AnalyticsPage() {
  const router = useRouter();
  const [scoreboard, setScoreboard] = useState<any>(null);
  const [token, setToken] = useState<string | null>(null);
  const [showToken, setShowToken] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  useEffect(() => {
    loadScoreboard();
  }, []);

  const loadScoreboard = async () => {
    try {
      setLoading(true);
      const data = await api.analytics.scoreboard();
      setScoreboard(data.scoreboard);
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) {
        router.push('/login');
      } else {
        setError('Failed to load analytics');
      }
    } finally {
      setLoading(false);
    }
  };

  const handleGenerateToken = async () => {
    try {
      const data = await api.analytics.generateToken();
      setToken(data.token);
      setShowToken(true);
    } catch (err) {
      if (err instanceof ApiError) {
        setError(err.message);
      } else {
        setError('Failed to generate token');
      }
    }
  };

  const handleRotateToken = async () => {
    try {
      const data = await api.analytics.rotateToken();
      setToken(data.token);
      setShowToken(true);
    } catch (err) {
      setError('Failed to rotate token');
    }
  };

  if (loading) return <div className="p-8">Loading...</div>;
  if (error) return <div className="p-8 text-red-600">{error}</div>;

  return (
    <div className="min-h-screen bg-gray-50 p-8">
      <div className="max-w-4xl mx-auto">
        <h1 className="text-2xl font-bold mb-6">Analytics</h1>

        <div className="bg-white rounded-lg shadow p-6 mb-6">
          <h2 className="text-xl font-semibold mb-4">Scoreboard</h2>
          {scoreboard && (
            <div className="grid grid-cols-3 gap-4">
              <div>
                <div className="text-2xl font-bold text-green-600">{scoreboard.published_count || 0}</div>
                <div className="text-sm text-gray-600">Published</div>
              </div>
              <div>
                <div className="text-2xl font-bold text-blue-600">{scoreboard.approved_count || 0}</div>
                <div className="text-sm text-gray-600">Approved</div>
              </div>
              <div>
                <div className="text-2xl font-bold text-gray-600">{scoreboard.draft_count || 0}</div>
                <div className="text-sm text-gray-600">Draft</div>
              </div>
            </div>
          )}
        </div>

        <div className="bg-white rounded-lg shadow p-6 mb-6">
          <h2 className="text-xl font-semibold mb-4">Analytics Ingestion</h2>
          <p className="text-gray-600 mb-4">
            Use this token to send analytics events from your backend. The token is shown only once.
          </p>
          
          {showToken && token && (
            <div className="mb-4 p-4 bg-yellow-50 border border-yellow-200 rounded">
              <p className="text-sm font-medium mb-2">Save this token securely:</p>
              <code className="block p-2 bg-white rounded text-sm break-all">{token}</code>
            </div>
          )}

          <div className="flex gap-4 mb-6">
            <button
              onClick={handleGenerateToken}
              className="px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700"
            >
              Generate Token
            </button>
            <button
              onClick={handleRotateToken}
              className="px-4 py-2 border rounded-md hover:bg-gray-50"
            >
              Rotate Token
            </button>
          </div>

          <div className="space-y-4">
            <div>
              <h3 className="font-medium mb-2">JavaScript Snippet (for your backend):</h3>
              <pre className="bg-gray-100 p-4 rounded text-sm overflow-x-auto">
{`fetch('${process.env.NEXT_PUBLIC_API_URL || 'http://localhost:3001'}/v1/analytics/events', {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    'X-Analytics-Token': 'YOUR_TOKEN_HERE'
  },
  body: JSON.stringify({
    event_id: 'user_signup',
    occurred_at: new Date().toISOString(),
    type: 'conversion',
    utm_source: 'google',
    utm_medium: 'cpc',
    utm_campaign: 'summer2024'
  })
});`}
              </pre>
            </div>

            <div>
              <h3 className="font-medium mb-2">cURL Example:</h3>
              <pre className="bg-gray-100 p-4 rounded text-sm overflow-x-auto">
{`curl -X POST '${process.env.NEXT_PUBLIC_API_URL || 'http://localhost:3001'}/v1/analytics/events' \\
  -H 'Content-Type: application/json' \\
  -H 'X-Analytics-Token: YOUR_TOKEN_HERE' \\
  -d '{
    "event_id": "user_signup",
    "occurred_at": "2024-01-15T10:00:00Z",
    "type": "conversion",
    "utm_source": "google",
    "utm_medium": "cpc",
    "utm_campaign": "summer2024"
  }'`}
              </pre>
            </div>

            <div>
              <h3 className="font-medium mb-2">Canonical UTM Format:</h3>
              <p className="text-sm text-gray-600">
                Use these UTM parameters for consistent tracking:
              </p>
              <ul className="text-sm text-gray-600 list-disc list-inside mt-2">
                <li>utm_source: Traffic source (e.g., google, twitter, newsletter)</li>
                <li>utm_medium: Marketing medium (e.g., cpc, email, social)</li>
                <li>utm_campaign: Campaign name (e.g., summer2024, product_launch)</li>
                <li>utm_term: Search term (optional, for paid search)</li>
                <li>utm_content: Content identifier (optional, for A/B testing)</li>
              </ul>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

