'use client';

import { useEffect, useState } from 'react';
import { useRouter, useParams } from 'next/navigation';
import { api, ApiError } from '@/lib/api';

export default function ContentDetailPage() {
  const router = useRouter();
  const params = useParams();
  const id = params.id as string;

  const [item, setItem] = useState<any>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [editingVariant, setEditingVariant] = useState<string | null>(null);
  const [editContent, setEditContent] = useState('');

  useEffect(() => {
    loadItem();
  }, [id]);

  const loadItem = async () => {
    try {
      setLoading(true);
      const data = await api.content.get(id);
      setItem(data.item);
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) {
        router.push('/login');
      } else {
        setError('Failed to load content');
      }
    } finally {
      setLoading(false);
    }
  };

  const handleApprove = async () => {
    try {
      await api.content.approve(id);
      loadItem();
    } catch (err) {
      setError('Failed to approve');
    }
  };

  const handleReject = async () => {
    try {
      await api.content.reject(id);
      loadItem();
    } catch (err) {
      setError('Failed to reject');
    }
  };

  const handleEditVariant = (variant: any) => {
    setEditingVariant(variant.id);
    setEditContent(variant.content || '');
  };

  const handleSaveVariant = async () => {
    if (!editingVariant) return;
    try {
      await api.content.updateVariant(id, editingVariant, editContent);
      setEditingVariant(null);
      loadItem();
    } catch (err) {
      setError('Failed to update variant');
    }
  };

  if (loading) return <div className="p-8">Loading...</div>;
  if (error) return <div className="p-8 text-red-600">{error}</div>;
  if (!item) return <div className="p-8">Content not found</div>;

  const variants = item.variants || [];

  return (
    <div className="min-h-screen bg-gray-50 p-8">
      <div className="max-w-4xl mx-auto">
        <div className="mb-6">
          <button
            onClick={() => router.back()}
            className="text-blue-600 hover:underline mb-4"
          >
            ← Back to Content
          </button>
          <h1 className="text-2xl font-bold">Content Item</h1>
          <p className="text-gray-600">ID: {item.id}</p>
          <p className="text-gray-600">Status: {item.status}</p>
          {item.calendar_date && <p className="text-gray-600">Date: {item.calendar_date}</p>}
        </div>

        <div className="bg-white rounded-lg shadow p-6 mb-6">
          <h2 className="text-xl font-semibold mb-4">Variants</h2>
          {variants.length === 0 ? (
            <p className="text-gray-500">No variants yet</p>
          ) : (
            <div className="space-y-4">
              {variants.map((variant: any) => (
                <div key={variant.id} className="border rounded-lg p-4">
                  <div className="flex justify-between items-start mb-2">
                    <div>
                      <span className="font-medium">Platform: {variant.platform || 'N/A'}</span>
                      {variant.warnings && variant.warnings.length > 0 && (
                        <div className="mt-2">
                          {variant.warnings.map((w: string, i: number) => (
                            <div key={i} className="text-yellow-600 text-sm">⚠ {w}</div>
                          ))}
                        </div>
                      )}
                    </div>
                    {item.status !== 'published' && (
                      <button
                        onClick={() => handleEditVariant(variant)}
                        className="text-blue-600 hover:underline text-sm"
                      >
                        Edit
                      </button>
                    )}
                  </div>
                  {editingVariant === variant.id ? (
                    <div className="space-y-2">
                      <textarea
                        value={editContent}
                        onChange={(e) => setEditContent(e.target.value)}
                        rows={6}
                        className="w-full px-3 py-2 border rounded-md"
                      />
                      <div className="flex gap-2">
                        <button
                          onClick={handleSaveVariant}
                          className="px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700"
                        >
                          Save
                        </button>
                        <button
                          onClick={() => setEditingVariant(null)}
                          className="px-4 py-2 border rounded-md hover:bg-gray-50"
                        >
                          Cancel
                        </button>
                      </div>
                    </div>
                  ) : (
                    <div className="text-gray-700 whitespace-pre-wrap">{variant.content}</div>
                  )}
                </div>
              ))}
            </div>
          )}
        </div>

        {item.status !== 'published' && (
          <div className="flex gap-4">
            <button
              onClick={handleApprove}
              className="px-6 py-2 bg-green-600 text-white rounded-md hover:bg-green-700"
            >
              Approve
            </button>
            <button
              onClick={handleReject}
              className="px-6 py-2 bg-red-600 text-white rounded-md hover:bg-red-700"
            >
              Reject
            </button>
          </div>
        )}
      </div>
    </div>
  );
}

