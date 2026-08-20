I want to store the backtest feed and the computed metrics from the processing of that feed.

metrics:
- return %/abs
- high watermark %/abs
- low watermark %/abs
- max drawdown %/abs
- sharpe ratio
- volatility
- trade count
- total fees
- target position changes
- calmar ratio
- sortino ratio
- turnover
- volume
- pnl
- portfolio value

Some of these are bound to a specific point in time (high watermark, low watermark, max drawdown).
Some are both percentage and absolute values
Some are aggregates (volume)


do I have enough data in the knowledge-base/docs/specs/SPEC-backtest-feed.md to compute it all?

Give me a brief regarding every metric and the data it needs.

Fee is 50% of the slippage parameter for now, so I need a fee trait
