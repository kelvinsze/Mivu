import { describe, it, expect } from 'vitest';
import { validateRatingsQuery, isValidImdbId, isValidPositiveInteger, isValidMediaType } from '../src/utils/validation';

describe('Validation Unit Tests', () => {
  describe('isValidImdbId', () => {
    it('accepts valid IMDb IDs', () => {
      expect(isValidImdbId('tt0903747')).toBe(true);
      expect(isValidImdbId('tt0111161')).toBe(true);
      expect(isValidImdbId('tt1234567890')).toBe(true);
    });

    it('rejects invalid IMDb IDs', () => {
      expect(isValidImdbId('')).toBe(false);
      expect(isValidImdbId(null)).toBe(false);
      expect(isValidImdbId('1234567')).toBe(false);
      expect(isValidImdbId('tt123')).toBe(false); // too short
      expect(isValidImdbId('nm0000123')).toBe(false); // name id
      expect(isValidImdbId('ttabcdefg')).toBe(false);
    });
  });

  describe('isValidPositiveInteger', () => {
    it('accepts positive integers', () => {
      expect(isValidPositiveInteger(1)).toBe(true);
      expect(isValidPositiveInteger('1396')).toBe(true);
      expect(isValidPositiveInteger(278)).toBe(true);
    });

    it('rejects zero, negative numbers, and non-integers', () => {
      expect(isValidPositiveInteger(0)).toBe(false);
      expect(isValidPositiveInteger(-10)).toBe(false);
      expect(isValidPositiveInteger('0')).toBe(false);
      expect(isValidPositiveInteger('-5')).toBe(false);
      expect(isValidPositiveInteger('abc')).toBe(false);
      expect(isValidPositiveInteger(3.14)).toBe(false);
    });
  });

  describe('isValidMediaType', () => {
    it('accepts movie and tv', () => {
      expect(isValidMediaType('movie')).toBe(true);
      expect(isValidMediaType('tv')).toBe(true);
    });

    it('rejects other types', () => {
      expect(isValidMediaType('series')).toBe(false);
      expect(isValidMediaType('show')).toBe(false);
      expect(isValidMediaType('anime')).toBe(false);
      expect(isValidMediaType('')).toBe(false);
    });
  });

  describe('validateRatingsQuery', () => {
    it('rejects request with no identifiers', () => {
      const result = validateRatingsQuery({});
      expect(result.valid).toBe(false);
      expect(result.error?.code).toBe('MISSING_IDENTIFIER');
    });

    it('accepts valid IMDb query without type', () => {
      const result = validateRatingsQuery({ imdb: 'tt0903747' });
      expect(result.valid).toBe(true);
      expect(result.data?.imdb).toBe('tt0903747');
    });

    it('rejects malformed IMDb ID', () => {
      const result = validateRatingsQuery({ imdb: 'not-an-imdb' });
      expect(result.valid).toBe(false);
      expect(result.error?.code).toBe('INVALID_IMDB_ID');
    });

    it('accepts valid TMDb query with media type', () => {
      const result = validateRatingsQuery({ tmdb: '1396', type: 'tv' });
      expect(result.valid).toBe(true);
      expect(result.data?.tmdb).toBe(1396);
      expect(result.data?.type).toBe('tv');
    });

    it('rejects TMDb query without media type', () => {
      const result = validateRatingsQuery({ tmdb: '1396' });
      expect(result.valid).toBe(false);
      expect(result.error?.code).toBe('MISSING_MEDIA_TYPE');
    });

    it('rejects invalid media type', () => {
      const result = validateRatingsQuery({ tmdb: '1396', type: 'podcast' });
      expect(result.valid).toBe(false);
      expect(result.error?.code).toBe('INVALID_MEDIA_TYPE');
    });
  });
});
