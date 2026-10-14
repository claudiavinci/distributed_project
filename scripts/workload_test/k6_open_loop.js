import http from 'k6/http';
import { check } from 'k6';


export const options = {
    scenarios: {
        open_loop: {
            executor: 'constant-arrival-rate',
            rate: Number(ENV.RATE),
            timeUnit: '1s',
            duration: ENV.DURATION,
            preAllocatedVUs:
                Number(ENV.PRE_VUS),
            maxVUs:
                Number(ENV.MAX_VUS),
        },
    },

    thresholds: {
        dropped_iterations: [
            'count==0'
        ]
    },

    // per analisi sperimentale
    summaryTrendStats: [
        'avg',
        'med',
        'min',
        'max',
        'p(90)',
        'p(95)',
        'p(99)'
    ],

    // per Online Boutique terrei il body
    discardResponseBodies: false
};

export default function () {
    let response = http.get(
        ENV.TARGET_URL,
        {
            timeout: ENV.REQ_TIMEOUT,
            tags: {
                test:
                    ENV.TEST_NAME || "baseline",
                rate:
                    ENV.RATE
            }
        }
    );

    check(response, {
        "frontend reachable":
            (r) => r.status === 200
    });
}