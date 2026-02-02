'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { api, ApiError } from '@/lib/api';

export default function SettingsPage() {
  const router = useRouter();
  const [settings, setSettings] = useState<any>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  const [publishingEnabled, setPublishingEnabled] = useState(false);
  const [timezone, setTimezone] = useState('UTC');
  const [slackWebhook, setSlackWebhook] = useState('');
  const [bufferProfiles, setBufferProfiles] = useState<string[]>([]);

  useEffect(() => {
    loadSettings();
  }, []);

  const loadSettings = async () => {
    try {
      setLoading(true);
      const data = await api.settings.get();
      const s = data.settings;
      setSettings(s);
      setPublishingEnabled(s.publishing_enabled || false);
      setTimezone(s.timezone || 'UTC');
      setSlackWebhook(s.slack_webhook_url || '');
      setBufferProfiles((s.buffer_profiles || []).map((p: any) => p.id || p));
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) {
        router.push('/login');
      } else {
        setError('Failed to load settings');
      }
    } finally {
      setLoading(false);
    }
  };

  const handleSave = async () => {
    try {
      setSaving(true);
      await api.settings.update({
        publishing_enabled: publishingEnabled,
        timezone,
        slack_webhook_url: slackWebhook,
        buffer_profiles: bufferProfiles.map((id) => ({ id, name: id })),
      });
      setError('');
      alert('Settings saved');
    } catch (err) {
      setError('Failed to save settings');
    } finally {
      setSaving(false);
    }
  };

  if (loading) return <div className="p-8">Loading...</div>;
  if (error && !settings) return <div className="p-8 text-red-600">{error}</div>;

  return (
    <div className="min-h-screen bg-gray-50 p-8">
      <div className="max-w-2xl mx-auto">
        <h1 className="text-2xl font-bold mb-6">Settings</h1>

        <div className="bg-white rounded-lg shadow p-6 space-y-6">
          <div>
            <label className="flex items-center gap-2">
              <input
                type="checkbox"
                checked={publishingEnabled}
                onChange={(e) => setPublishingEnabled(e.target.checked)}
                className="rounded"
              />
              <span className="font-medium">Publishing Enabled</span>
            </label>
            <p className="text-sm text-gray-600 mt-1">
              Enable automatic publishing of approved content
            </p>
          </div>

          <div>
            <label className="block text-sm font-medium mb-1">Timezone</label>
            <select
              value={timezone}
              onChange={(e) => setTimezone(e.target.value)}
              className="w-full px-3 py-2 border rounded-md"
            >
              <option value="UTC">UTC</option>
              <option value="America/New_York">Eastern Time</option>
              <option value="America/Chicago">Central Time</option>
              <option value="America/Denver">Mountain Time</option>
              <option value="America/Los_Angeles">Pacific Time</option>
            </select>
          </div>

          <div>
            <label className="block text-sm font-medium mb-1">Slack Webhook URL</label>
            <input
              type="url"
              value={slackWebhook}
              onChange={(e) => setSlackWebhook(e.target.value)}
              placeholder="https://hooks.slack.com/services/..."
              className="w-full px-3 py-2 border rounded-md"
            />
            {settings?.slack_webhook_url && !slackWebhook && (
              <p className="text-xs text-gray-500 mt-1">Current: [Configured]</p>
            )}
          </div>

          <div>
            <label className="block text-sm font-medium mb-1">Buffer Profiles (comma-separated IDs)</label>
            <input
              type="text"
              value={bufferProfiles.join(',')}
              onChange={(e) => setBufferProfiles(e.target.value.split(',').filter(Boolean))}
              placeholder="profile1,profile2"
              className="w-full px-3 py-2 border rounded-md"
            />
            {settings?.buffer_profiles && settings.buffer_profiles.length > 0 && (
              <p className="text-xs text-gray-500 mt-1">
                Current: {settings.buffer_profiles.map((p: any) => p.id || p.name).join(', ')}
              </p>
            )}
          </div>

          {settings?.buffer_access_token && (
            <div>
              <p className="text-sm text-gray-600">Buffer Access Token: [REDACTED]</p>
              <p className="text-xs text-gray-500 mt-1">
                Token is stored securely and not displayed
              </p>
            </div>
          )}

          {error && <div className="text-red-600 text-sm">{error}</div>}

          <button
            onClick={handleSave}
            disabled={saving}
            className="w-full px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 disabled:opacity-50"
          >
            {saving ? 'Saving...' : 'Save Settings'}
          </button>
        </div>
      </div>
    </div>
  );
}

