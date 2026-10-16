import http from 'k6/http';
import { check } from 'k6';

// Tutti i valori arrivano da exp_config.conf tramite lo script bash (flag -e).
export const options = {
  scenarios: {
    open_loop: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE),
      timeUnit: '1s',
      duration: __ENV.DURATION,
      preAllocatedVUs: Number(__ENV.PRE_VUS),
      maxVUs: Number(__ENV.MAX_VUS),
    },
  },
  discardResponseBodies: true,
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

export default function () {
  const res = http.get(__ENV.TARGET_URL, { timeout: __ENV.REQ_TIMEOUT });
  check(res, {
    'frontend reachable': (r) => r.status === 200,
  });
}