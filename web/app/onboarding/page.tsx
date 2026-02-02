'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { api, ApiError } from '@/lib/api';

type Step = 1 | 2 | 3 | 4 | 5 | 6 | 7;

export default function OnboardingPage() {
  const router = useRouter();
  const [step, setStep] = useState<Step>(1);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  // Step 1: Product basics
  const [productName, setProductName] = useState('');
  const [websiteUrl, setWebsiteUrl] = useState('');
  const [category, setCategory] = useState('');
  const [brandVoice, setBrandVoice] = useState('');

  // Step 2: Strategy
  const [icpRole, setIcpRole] = useState('');
  const [painPoints, setPainPoints] = useState('');
  const [differentiators, setDifferentiators] = useState('');
  const [offer, setOffer] = useState('');
  const [pricingModel, setPricingModel] = useState('');
  const [proofAssets, setProofAssets] = useState('');

  // Step 3: Brief ID (from enrich)
  const [briefId, setBriefId] = useState<string | null>(null);

  // Step 4: Calendar
  const [cadence, setCadence] = useState('weekly');
  const [startDate, setStartDate] = useState('');

  // Step 6: Integrations
  const [slackWebhook, setSlackWebhook] = useState('');
  const [bufferToken, setBufferToken] = useState('');
  const [bufferProfiles, setBufferProfiles] = useState<string[]>([]);

  const handleNext = async () => {
    setError('');
    setLoading(true);

    try {
      if (step === 3) {
        // Enrich brief
        if (!briefId) {
          setError('Please create a brief first');
          return;
        }
        await api.briefs.enrich(briefId);
      } else if (step === 4) {
        // Generate calendar (simplified - would create multiple items)
        const date = new Date(startDate);
        await api.calendar.generateDrafts(date.toISOString().split('T')[0], briefId || undefined);
      } else if (step === 6) {
        // Save integrations
        await api.settings.update({
          slack_webhook_url: slackWebhook,
          buffer_access_token: bufferToken,
          buffer_profiles: bufferProfiles.map(p => ({ id: p, name: p })),
        });
      } else if (step === 7) {
        // Enable publishing
        await api.settings.update({ publishing_enabled: true });
        router.push('/content');
        return;
      }

      if (step < 7) {
        setStep((s) => (s + 1) as Step);
      }
    } catch (err) {
      if (err instanceof ApiError) {
        setError(err.message);
      } else {
        setError('Step failed');
      }
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen bg-gray-50 p-8">
      <div className="max-w-2xl mx-auto bg-white rounded-lg shadow p-8">
        <h1 className="text-2xl font-bold mb-6">Onboarding</h1>
        <div className="mb-6">
          <div className="flex justify-between mb-2">
            <span className="text-sm text-gray-600">Step {step} of 7</span>
            <span className="text-sm text-gray-600">{Math.round((step / 7) * 100)}%</span>
          </div>
          <div className="w-full bg-gray-200 rounded-full h-2">
            <div
              className="bg-blue-600 h-2 rounded-full transition-all"
              style={{ width: `${(step / 7) * 100}%` }}
            />
          </div>
        </div>

        {error && <div className="text-red-600 text-sm mb-4">{error}</div>}

        {step === 1 && (
          <div className="space-y-4">
            <h2 className="text-xl font-semibold">Product Basics</h2>
            <div>
              <label className="block text-sm font-medium mb-1">Product Name</label>
              <input
                type="text"
                value={productName}
                onChange={(e) => setProductName(e.target.value)}
                className="w-full px-3 py-2 border rounded-md"
              />
            </div>
            <div>
              <label className="block text-sm font-medium mb-1">Website URL</label>
              <input
                type="url"
                value={websiteUrl}
                onChange={(e) => setWebsiteUrl(e.target.value)}
                className="w-full px-3 py-2 border rounded-md"
              />
            </div>
            <div>
              <label className="block text-sm font-medium mb-1">Category</label>
              <input
                type="text"
                value={category}
                onChange={(e) => setCategory(e.target.value)}
                className="w-full px-3 py-2 border rounded-md"
              />
            </div>
            <div>
              <label className="block text-sm font-medium mb-1">Brand Voice</label>
              <textarea
                value={brandVoice}
                onChange={(e) => setBrandVoice(e.target.value)}
                rows={4}
                className="w-full px-3 py-2 border rounded-md"
              />
            </div>
          </div>
        )}

        {step === 2 && (
          <div className="space-y-4">
            <h2 className="text-xl font-semibold">Strategy</h2>
            <div>
              <label className="block text-sm font-medium mb-1">ICP Role</label>
              <input
                type="text"
                value={icpRole}
                onChange={(e) => setIcpRole(e.target.value)}
                className="w-full px-3 py-2 border rounded-md"
              />
            </div>
            <div>
              <label className="block text-sm font-medium mb-1">Pain Points</label>
              <textarea
                value={painPoints}
                onChange={(e) => setPainPoints(e.target.value)}
                rows={3}
                className="w-full px-3 py-2 border rounded-md"
              />
            </div>
            <div>
              <label className="block text-sm font-medium mb-1">Differentiators</label>
              <textarea
                value={differentiators}
                onChange={(e) => setDifferentiators(e.target.value)}
                rows={3}
                className="w-full px-3 py-2 border rounded-md"
              />
            </div>
            <div>
              <label className="block text-sm font-medium mb-1">Offer</label>
              <textarea
                value={offer}
                onChange={(e) => setOffer(e.target.value)}
                rows={2}
                className="w-full px-3 py-2 border rounded-md"
              />
            </div>
            <div>
              <label className="block text-sm font-medium mb-1">Pricing Model</label>
              <input
                type="text"
                value={pricingModel}
                onChange={(e) => setPricingModel(e.target.value)}
                className="w-full px-3 py-2 border rounded-md"
              />
            </div>
            <div>
              <label className="block text-sm font-medium mb-1">Proof Assets</label>
              <textarea
                value={proofAssets}
                onChange={(e) => setProofAssets(e.target.value)}
                rows={2}
                className="w-full px-3 py-2 border rounded-md"
              />
            </div>
          </div>
        )}

        {step === 3 && (
          <div className="space-y-4">
            <h2 className="text-xl font-semibold">Enrich from Website</h2>
            <p className="text-gray-600">
              Click the button below to enrich your brief from your website.
            </p>
            <button
              onClick={handleNext}
              disabled={loading}
              className="bg-blue-600 text-white px-4 py-2 rounded-md hover:bg-blue-700 disabled:opacity-50"
            >
              {loading ? 'Enriching...' : 'Enrich Brief'}
            </button>
          </div>
        )}

        {step === 4 && (
          <div className="space-y-4">
            <h2 className="text-xl font-semibold">Generate Calendar</h2>
            <div>
              <label className="block text-sm font-medium mb-1">Cadence</label>
              <select
                value={cadence}
                onChange={(e) => setCadence(e.target.value)}
                className="w-full px-3 py-2 border rounded-md"
              >
                <option value="daily">Daily</option>
                <option value="weekly">Weekly</option>
                <option value="biweekly">Bi-weekly</option>
              </select>
            </div>
            <div>
              <label className="block text-sm font-medium mb-1">Start Date</label>
              <input
                type="date"
                value={startDate}
                onChange={(e) => setStartDate(e.target.value)}
                className="w-full px-3 py-2 border rounded-md"
              />
            </div>
            <button
              onClick={handleNext}
              disabled={loading || !startDate}
              className="bg-blue-600 text-white px-4 py-2 rounded-md hover:bg-blue-700 disabled:opacity-50"
            >
              {loading ? 'Generating...' : 'Generate Calendar'}
            </button>
          </div>
        )}

        {step === 5 && (
          <div className="space-y-4">
            <h2 className="text-xl font-semibold">Generate Drafts</h2>
            <p className="text-gray-600">
              Generating drafts for the first 3 calendar items...
            </p>
            <button
              onClick={handleNext}
              disabled={loading}
              className="bg-blue-600 text-white px-4 py-2 rounded-md hover:bg-blue-700 disabled:opacity-50"
            >
              {loading ? 'Generating...' : 'Generate Drafts'}
            </button>
          </div>
        )}

        {step === 6 && (
          <div className="space-y-4">
            <h2 className="text-xl font-semibold">Connect Integrations</h2>
            <div>
              <label className="block text-sm font-medium mb-1">Slack Webhook URL</label>
              <input
                type="url"
                value={slackWebhook}
                onChange={(e) => setSlackWebhook(e.target.value)}
                placeholder="https://hooks.slack.com/services/..."
                className="w-full px-3 py-2 border rounded-md"
              />
            </div>
            <div>
              <label className="block text-sm font-medium mb-1">Buffer Access Token</label>
              <input
                type="password"
                value={bufferToken}
                onChange={(e) => setBufferToken(e.target.value)}
                placeholder="Paste your Buffer access token"
                className="w-full px-3 py-2 border rounded-md"
              />
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
            </div>
            <button
              onClick={handleNext}
              disabled={loading}
              className="bg-blue-600 text-white px-4 py-2 rounded-md hover:bg-blue-700 disabled:opacity-50"
            >
              {loading ? 'Saving...' : 'Save Integrations'}
            </button>
          </div>
        )}

        {step === 7 && (
          <div className="space-y-4">
            <h2 className="text-xl font-semibold">Schedule & Publish</h2>
            <p className="text-gray-600">
              Enable publishing to start scheduling approved content.
            </p>
            <button
              onClick={handleNext}
              disabled={loading}
              className="bg-blue-600 text-white px-4 py-2 rounded-md hover:bg-blue-700 disabled:opacity-50"
            >
              {loading ? 'Enabling...' : 'Enable Publishing'}
            </button>
          </div>
        )}

        <div className="mt-8 flex justify-between">
          {step > 1 && (
            <button
              onClick={() => setStep((s) => (s - 1) as Step)}
              className="px-4 py-2 border rounded-md hover:bg-gray-50"
            >
              Previous
            </button>
          )}
          <div className="flex-1" />
          {step < 7 && (
            <button
              onClick={handleNext}
              disabled={loading}
              className="px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 disabled:opacity-50"
            >
              Next
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

