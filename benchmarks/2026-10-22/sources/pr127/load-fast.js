import http from 'k6/http';
import { check, sleep } from 'k6';
import { SharedArray } from 'k6/data';

const BASE_URL =
  __ENV.BASE_URL ||
  'http://127.0.0.1:3000';

const VUS =
  Number(__ENV.VUS || 1000);

const LIKE_PROB = 0.15;
const POST_PROB = 0.02;

const tokens = new SharedArray(
  'tokens',
  () =>
    JSON.parse(
      open(
        __ENV.TOKENS ||
        '../../seed/tokens.json'
      )
    )
);

export const options = {
  scenarios: {
    users: {
      executor: 'constant-vus',
      vus: VUS,
      duration:
        __ENV.DURATION || '30s'
    }
  },

  thresholds: {
    http_req_failed: [
      'rate<0.01'
    ]
  },

  summaryTrendStats: [
    'avg',
    'med',
    'p(95)',
    'p(99)',
    'max'
  ]
};

function random(lo, hi) {
  return lo + Math.random() * (hi - lo);
}

export default function () {
  const user =
    tokens[
      (__VU - 1) %
      tokens.length
    ];

  const auth = {
    headers: {
      Authorization:
        `Bearer ${user.token}`,
      'Content-Type':
        'application/json'
    }
  };

  //
  // health
  //
  if ((__ITER % 50) === 0) {
    const health = http.get(
      `${BASE_URL}/health`,
      {
        tags: {
          endpoint: 'health'
        }
      }
    );

    check(health, {
      'health 200':
        r => r.status === 200
    });
  }

  //
  // feed
  //
  const feed = http.get(
    `${BASE_URL}/feed`,
    {
      tags: {
        endpoint: 'feed'
      }
    }
  );

  if (
    !check(feed, {
      'feed 200':
        r => r.status === 200
    })
  ) {
    return;
  }

  const posts =
    feed.json('posts');

  if (
    !posts ||
    posts.length === 0
  ) {
    return;
  }

  //
  // more humanly post choosing
  //
  const post =
    posts[
      (__ITER + __VU) %
      posts.length
    ];

  sleep(
    random(0.01, 0.03)
  );

  //
  // post details
  //
  const postResp = http.get(
    `${BASE_URL}/posts/${post.id}`,
    {
      tags: {
        endpoint: 'post'
      }
    }
  );

  check(postResp, {
    'post 200':
      r => r.status === 200
  });

  sleep(
    random(0.01, 0.03)
  );

  //
  // like
  //
  if (
    Math.random() < LIKE_PROB
  ) {
    const like = http.post(
      `${BASE_URL}/posts/${post.id}/like`,
      null,
      {
        ...auth,
        tags: {
          endpoint: 'like'
        }
      }
    );

    check(like, {
      'like 200|201':
        r =>
          r.status === 200 ||
          r.status === 201
    });
  }

  //
  // create
  //
  if (
    Math.random() < POST_PROB
  ) {
    const create = http.post(
      `${BASE_URL}/posts`,
      JSON.stringify({
        body:
          `${user.username}-${__VU}-${__ITER}`
      }),
      {
        ...auth,
        tags: {
          endpoint: 'create'
        }
      }
    );

    check(create, {
      'create 201':
        r => r.status === 201
    });
  }

  sleep(
    random(0.01, 0.03)
  );
}