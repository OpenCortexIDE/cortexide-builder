'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { api, ApiError } from '@/lib/api';

export default function CalendarPage() {
  const router = useRouter();
  const [calendar, setCalendar] = useState<Record<string, any[]>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  useEffect(() => {
    loadCalendar();
  }, []);

  const loadCalendar = async () => {
    try {
      setLoading(true);
      const data = await api.calendar.get();
      setCalendar(data.calendar || {});
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) {
        router.push('/login');
      } else {
        setError('Failed to load calendar');
      }
    } finally {
      setLoading(false);
    }
  };

  const handleGenerateDrafts = async (date: string) => {
    try {
      await api.calendar.generateDrafts(date);
      loadCalendar();
    } catch (err) {
      setError('Failed to generate drafts');
    }
  };

  if (loading) return <div className="p-8">Loading...</div>;
  if (error) return <div className="p-8 text-red-600">{error}</div>;

  // Generate 30 days
  const dates = [];
  const today = new Date();
  for (let i = 0; i < 30; i++) {
    const date = new Date(today);
    date.setDate(date.getDate() + i);
    dates.push(date.toISOString().split('T')[0]);
  }

  return (
    <div className="min-h-screen bg-gray-50 p-8">
      <div className="max-w-6xl mx-auto">
        <div className="flex justify-between items-center mb-6">
          <h1 className="text-2xl font-bold">Calendar</h1>
          <div className="flex gap-4">
            <a
              href="/content"
              className="px-4 py-2 border rounded-md hover:bg-gray-50"
            >
              Content
            </a>
            <a
              href="/settings"
              className="px-4 py-2 border rounded-md hover:bg-gray-50"
            >
              Settings
            </a>
          </div>
        </div>

        <div className="bg-white rounded-lg shadow p-6">
          <div className="grid grid-cols-7 gap-4">
            {dates.map((date) => {
              const items = calendar[date] || [];
              return (
                <div key={date} className="border rounded-lg p-3 min-h-[120px]">
                  <div className="text-sm font-medium mb-2">
                    {new Date(date).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}
                  </div>
                  {items.map((item) => (
                    <div
                      key={item.id}
                      className={`text-xs p-1 mb-1 rounded ${
                        item.status === 'published'
                          ? 'bg-green-100'
                          : item.status === 'approved'
                          ? 'bg-blue-100'
                          : 'bg-gray-100'
                      }`}
                    >
                      {item.status}
                    </div>
                  ))}
                  {items.length === 0 && (
                    <button
                      onClick={() => handleGenerateDrafts(date)}
                      className="text-xs text-blue-600 hover:underline"
                    >
                      Generate
                    </button>
                  )}
                </div>
              );
            })}
          </div>
        </div>
      </div>
    </div>
  );
}

