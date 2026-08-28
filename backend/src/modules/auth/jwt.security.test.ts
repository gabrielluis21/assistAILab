import {
    after,
    before,
    describe,
    test,
} from 'node:test';

import assert from 'node:assert/strict';

import {
    createHmac,
} from 'node:crypto';

import type {
    FastifyInstance,
} from 'fastify';

import {
    buildApp,
} from '../../app.js';

const JWT_SECRET =
    'sec-dep-01-jwt-security-test-secret';

const WRONG_JWT_SECRET =
    'sec-dep-01-wrong-jwt-security-test-secret';

const TEST_ROUTE =
    '/__sec-dep-01/jwt-security';

const basePayload = {
    sub:
        '00000000-0000-0000-0000-000000000001',

    role:
        'ADMIN',

    name:
        'SEC-DEP-01 JWT Test',

    customerId:
        null,

    organizationId:
        '00000000-0000-0000-0000-000000000002',
};

function encodeJson(
    value: Record<string, unknown>
): string {
    return Buffer
        .from(
            JSON.stringify(
                value
            )
        )
        .toString(
            'base64url'
        );
}

function signHmacJwt(
    {
        algorithm,
        hash,
        payload,
        secret,
    }: {
        algorithm:
        'HS256' | 'HS512';

        hash:
        'sha256' | 'sha512';

        payload:
        Record<string, unknown>;

        secret:
        string;
    }
): string {
    const encodedHeader =
        encodeJson({
            alg:
                algorithm,

            typ:
                'JWT',
        });

    const encodedPayload =
        encodeJson(
            payload
        );

    const signingInput =
        `${encodedHeader}.${encodedPayload}`;

    const signature =
        createHmac(
            hash,
            secret
        )
            .update(
                signingInput
            )
            .digest(
                'base64url'
            );

    return `${signingInput}.${signature}`;
}

function createNoneJwt(
    payload:
        Record<string, unknown>
): string {
    const encodedHeader =
        encodeJson({
            alg:
                'none',

            typ:
                'JWT',
        });

    const encodedPayload =
        encodeJson(
            payload
        );

    return `${encodedHeader}.${encodedPayload}.`;
}

function tamperSegment(
    value: string
): string {
    if (
        value.length === 0
    ) {
        throw new Error(
            'JWT segment cannot be empty'
        );
    }

    const replacement =
        value[0] ===
            'A'
            ? 'B'
            : 'A';

    return (
        replacement +
        value.slice(1)
    );
}

describe(
    'SEC-DEP-01 JWT security boundary',
    {
        concurrency:
            false,
    },
    () => {
        let app:
            FastifyInstance;

        let previousJwtSecret:
            string | undefined;

        before(
            async () => {
                previousJwtSecret =
                    process.env.JWT_SECRET;

                process.env.JWT_SECRET =
                    JWT_SECRET;

                app =
                    buildApp();

                app.get(
                    TEST_ROUTE,
                    {
                        preValidation: [
                            (
                                app as any
                            ).authenticate,
                        ],
                    },
                    async (
                        request
                    ) => {
                        return {
                            ok:
                                true,

                            user:
                                request.user,
                        };
                    }
                );

                await app.ready();
            }
        );

        after(
            async () => {
                await app.close();

                if (
                    previousJwtSecret
                ) {
                    process.env.JWT_SECRET =
                        previousJwtSecret;
                } else {
                    delete process
                        .env
                        .JWT_SECRET;
                }
            }
        );

        async function injectToken(
            token:
                string
        ) {
            return app.inject({
                method:
                    'GET',

                url:
                    TEST_ROUTE,

                headers: {
                    authorization:
                        `Bearer ${token}`,
                },
            });
        }

        function assertUnauthorized(
            response: {
                statusCode:
                number;

                json:
                () => unknown;
            }
        ) {
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

        test(
            'accepts a valid HS256 token',
            async () => {
                const token =
                    app.jwt.sign(
                        basePayload
                    );

                const [
                    encodedHeader,
                ] =
                    token.split('.');

                const header =
                    JSON.parse(
                        Buffer
                            .from(
                                encodedHeader,
                                'base64url'
                            )
                            .toString(
                                'utf8'
                            )
                    );

                assert.equal(
                    header.alg,
                    'HS256'
                );

                const response =
                    await injectToken(
                        token
                    );

                assert.equal(
                    response.statusCode,
                    200
                );

                const body =
                    response.json();

                assert.equal(
                    body.ok,
                    true
                );

                assert.equal(
                    body.user.sub,
                    basePayload.sub
                );

                assert.equal(
                    body.user.role,
                    basePayload.role
                );
            }
        );

        test(
            'rejects alg:none',
            async () => {
                const token =
                    createNoneJwt(
                        basePayload
                    );

                const response =
                    await injectToken(
                        token
                    );

                assertUnauthorized(
                    response
                );
            }
        );

        test(
            'rejects an unexpected HS512 algorithm',
            async () => {
                const now =
                    Math.floor(
                        Date.now() /
                        1000
                    );

                const token =
                    signHmacJwt({
                        algorithm:
                            'HS512',

                        hash:
                            'sha512',

                        secret:
                            JWT_SECRET,

                        payload: {
                            ...basePayload,

                            iat:
                                now,

                            exp:
                                now +
                                300,
                        },
                    });

                const response =
                    await injectToken(
                        token
                    );

                assertUnauthorized(
                    response
                );
            }
        );

        test(
            'rejects a tampered signature',
            async () => {
                const validToken =
                    app.jwt.sign(
                        basePayload
                    );

                const [
                    header,
                    payload,
                    signature,
                ] =
                    validToken.split('.');

                const token =
                    `${header}.${payload}.${tamperSegment(
                        signature
                    )}`;

                const response =
                    await injectToken(
                        token
                    );

                assertUnauthorized(
                    response
                );
            }
        );

        test(
            'rejects a tampered payload',
            async () => {
                const validToken =
                    app.jwt.sign(
                        basePayload
                    );

                const [
                    header,
                    ,
                    signature,
                ] =
                    validToken.split('.');

                const tamperedPayload =
                    encodeJson({
                        ...basePayload,

                        role:
                            'CUSTOMER',
                    });

                const token =
                    `${header}.${tamperedPayload}.${signature}`;

                const response =
                    await injectToken(
                        token
                    );

                assertUnauthorized(
                    response
                );
            }
        );

        test(
            'rejects an expired HS256 token',
            async () => {
                const now =
                    Math.floor(
                        Date.now() /
                        1000
                    );

                const token =
                    signHmacJwt({
                        algorithm:
                            'HS256',

                        hash:
                            'sha256',

                        secret:
                            JWT_SECRET,

                        payload: {
                            ...basePayload,

                            iat:
                                now -
                                120,

                            exp:
                                now -
                                60,
                        },
                    });

                const response =
                    await injectToken(
                        token
                    );

                assertUnauthorized(
                    response
                );
            }
        );

        test(
            'rejects a token signed with the wrong secret',
            async () => {
                const now =
                    Math.floor(
                        Date.now() /
                        1000
                    );

                const token =
                    signHmacJwt({
                        algorithm:
                            'HS256',

                        hash:
                            'sha256',

                        secret:
                            WRONG_JWT_SECRET,

                        payload: {
                            ...basePayload,

                            iat:
                                now,

                            exp:
                                now +
                                300,
                        },
                    });

                const response =
                    await injectToken(
                        token
                    );

                assertUnauthorized(
                    response
                );
            }
        );

        test(
            'rejects a malformed token',
            async () => {
                const response =
                    await injectToken(
                        'not-a-jwt'
                    );

                assertUnauthorized(
                    response
                );
            }
        );
    }
);
