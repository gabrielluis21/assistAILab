import {
  after,
  before,
  describe,
  test,
} from 'node:test';

import assert from 'node:assert/strict';

import type {
  FastifyInstance,
} from 'fastify';

import {
  buildApp,
} from '../../app.js';

import {
  AppError,
  ForbiddenError,
  NotFoundError,
} from '../utils/errors.js';

describe(
  'SEC-ERR-01 - Public Input Validation / Error Contract',
  {
    concurrency: false,
  },
  () => {
    let app:
      FastifyInstance;

    let oldJwtSecret:
      string | undefined;

    before(
      async () => {
        oldJwtSecret =
          process.env.JWT_SECRET;

        process.env.JWT_SECRET =
          'sec-err-01-http-regression-secret';

        app =
          buildApp();

        app.post(
          '/__sec-err-01/fastify-validation',
          {
            schema: {
              body: {
                type:
                  'object',

                required: [
                  'requiredField',
                ],

                properties: {
                  requiredField: {
                    type:
                      'string',
                  },
                },

                additionalProperties:
                  false,
              },
            },
          },
          async (
            _request,
            reply
          ) =>
            reply.send({
              ok:
                true,
            })
        );

        app.get(
          '/__sec-err-01/app-error',
          async () => {
            throw new AppError(
              'SEC-ERR-01 AppError preserved',
              409
            );
          }
        );

        app.get(
          '/__sec-err-01/forbidden',
          async () => {
            throw new ForbiddenError(
              'SEC-ERR-01 Forbidden preserved'
            );
          }
        );

        app.get(
          '/__sec-err-01/not-found',
          async () => {
            throw new NotFoundError(
              'SEC-ERR-01 Not Found preserved'
            );
          }
        );

        app.get(
          '/__sec-err-01/unexpected',
          async () => {
            throw new Error(
              'SEC_ERR_01_INTERNAL_SECRET_DIAGNOSTIC'
            );
          }
        );

        await app.ready();
      }
    );

    after(
      async () => {
        await app.close();

        if (oldJwtSecret) {
          process.env.JWT_SECRET =
            oldJwtSecret;
        } else {
          delete process.env.JWT_SECRET;
        }
      }
    );

    test(
      'Register malformed returns 400 with minimal validation contract',
      async () => {
        const secretPassword =
          'DO_NOT_ECHO_REGISTER_PASSWORD';

        const response =
          await app.inject({
            method:
              'POST',

            url:
              '/api/v1/auth/register',

            payload: {
              name:
                'X',

              email:
                'not-an-email',

              password:
                secretPassword,
            },
          });

        assert.equal(
          response.statusCode,
          400
        );

        assert.deepEqual(
          response.json(),
          {
            error:
              'Validation Error',
          }
        );

        assert.match(
          String(
            response.headers[
            'content-type'
            ] ?? ''
          ),
          /^application\/json\b/i
        );
        assert.equal(
          response.body.includes(
            secretPassword
          ),
          false
        );

        assert.equal(
          response.body.includes(
            'password'
          ),
          false
        );
      }
    );

    test(
      'Login malformed returns 400 without leaking password or payload',
      async () => {
        const secretPassword =
          'DO_NOT_ECHO_LOGIN_PASSWORD';

        const response =
          await app.inject({
            method:
              'POST',

            url:
              '/api/v1/auth/login',

            payload: {
              email:
                'invalid-email',

              password:
                secretPassword,
            },
          });

        assert.equal(
          response.statusCode,
          400
        );

        assert.deepEqual(
          response.json(),
          {
            error:
              'Validation Error',
          }
        );

        assert.equal(
          response.body.includes(
            secretPassword
          ),
          false
        );

        assert.equal(
          response.body.includes(
            'invalid-email'
          ),
          false
        );

        assert.equal(
          response.body.includes(
            'password'
          ),
          false
        );
      }
    );

    test(
      'Customer onboarding malformed returns 400 with minimal validation contract',
      async () => {
        const secretPassword =
          'short';

        const response =
          await app.inject({
            method:
              'POST',

            url:
              '/api/v1/auth/customer-onboarding/claim',

            payload: {
              token:
                'short-token',

              password:
                secretPassword,
            },
          });

        assert.equal(
          response.statusCode,
          400
        );

        assert.deepEqual(
          response.json(),
          {
            error:
              'Validation Error',
          }
        );

        assert.equal(
          response.body.includes(
            'short-token'
          ),
          false
        );

        assert.equal(
          response.body.includes(
            secretPassword
          ),
          false
        );
      }
    );

    test(
      'Fastify validation error returns the same minimal 400 contract',
      async () => {
        const response =
          await app.inject({
            method:
              'POST',

            url:
              '/__sec-err-01/fastify-validation',

            payload: {},
          });

        assert.equal(
          response.statusCode,
          400
        );

        assert.deepEqual(
          response.json(),
          {
            error:
              'Validation Error',
          }
        );

        assert.equal(
          'details' in
          response.json(),
          false
        );
      }
    );

    test(
      'AppError preserves its original status and message',
      async () => {
        const response =
          await app.inject({
            method:
              'GET',

            url:
              '/__sec-err-01/app-error',
          });

        assert.equal(
          response.statusCode,
          409
        );

        assert.deepEqual(
          response.json(),
          {
            error:
              'SEC-ERR-01 AppError preserved',
          }
        );
      }
    );

    test(
      'Forbidden remains 403',
      async () => {
        const response =
          await app.inject({
            method:
              'GET',

            url:
              '/__sec-err-01/forbidden',
          });

        assert.equal(
          response.statusCode,
          403
        );

        assert.deepEqual(
          response.json(),
          {
            error:
              'SEC-ERR-01 Forbidden preserved',
          }
        );
      }
    );

    test(
      'Not Found remains 404',
      async () => {
        const response =
          await app.inject({
            method:
              'GET',

            url:
              '/__sec-err-01/not-found',
          });

        assert.equal(
          response.statusCode,
          404
        );

        assert.deepEqual(
          response.json(),
          {
            error:
              'SEC-ERR-01 Not Found preserved',
          }
        );
      }
    );

    test(
      'Invalid JWT remains 401',
      async () => {
        const response =
          await app.inject({
            method:
              'GET',

            url:
              '/api/v1/auth/me',

            headers: {
              authorization:
                'Bearer definitely-not-a-valid-jwt',
            },
          });

        assert.equal(
          response.statusCode,
          401
        );

        assert.deepEqual(
          response.json(),
          {
            error:
              'Unauthorized',
          }
        );
      }
    );

    test(
      'Unexpected Error remains generic 500 and does not leak diagnostics',
      async () => {
        const response =
          await app.inject({
            method:
              'GET',

            url:
              '/__sec-err-01/unexpected',
          });

        assert.equal(
          response.statusCode,
          500
        );

        assert.deepEqual(
          response.json(),
          {
            error:
              'Internal Server Error',
          }
        );

        assert.equal(
          response.body.includes(
            'SEC_ERR_01_INTERNAL_SECRET_DIAGNOSTIC'
          ),
          false
        );

        assert.equal(
          response.body.includes(
            'stack'
          ),
          false
        );
      }
    );
  }
);