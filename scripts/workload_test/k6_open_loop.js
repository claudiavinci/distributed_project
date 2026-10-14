import http from 'k6/http';

// Tutti i valori arrivano da exp_config.conf tramite lo script bash (flag -e).
export const options = {
  scenarios: {
    open_loop: {
      executor: 'constant-arrival-rate',
      rate: Number(ENV.RATE),
      timeUnit: '1s',
      duration: ENV.DURATION,
      preAllocatedVUs: Number(ENV.PRE_VUS),
      maxVUs: Number(ENV.MAX_VUS),
    },
  },
  discardResponseBodies: true,
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

export default function () {
  http.get(ENV.TARGET_URL, { timeout: ENV.REQ_TIMEOUT });
}