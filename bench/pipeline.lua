-- wrk pipelining script for the TFB /plaintext row.
--
-- Drive lex-web with 16 HTTP/1.1 pipelined requests per connection,
-- which is what the published TFB leaderboard's plaintext column
-- reports. lex-web inherited pipelining via lex-lang 0.9.3's hyper +
-- tokio swap (PR #402), so this just lets wrk batch them.
--
-- Usage:
--   wrk -t2 -c64 -d15s --latency \
--       -s bench/pipeline.lua http://127.0.0.1:8080/plaintext
--
-- Tune the depth by setting PIPELINE_DEPTH (default 16):
--   PIPELINE_DEPTH=64 wrk ... -s bench/pipeline.lua ...

local depth = tonumber(os.getenv("PIPELINE_DEPTH")) or 16

local req = wrk.format("GET", nil, nil, nil)
local batch = req:rep(depth)

request = function()
  return batch
end

done = function(summary, latency, requests)
  io.write(string.format(
    "pipeline depth   %d\n" ..
    "requests sent    %d\n" ..
    "completed        %d\n" ..
    "req/sec (wall)   %.2f\n",
    depth, summary.requests, summary.requests, summary.requests / (summary.duration / 1e6)))
end
