// Excerpt from EventHaven (private repo): lib/payments/types.ts
// Opening comment and one example label genericized; types unchanged.

/**
 * The payment-provider seam.
 * EventHaven started Stripe-only. Some organizations must use Authorize.net,
 * so this is not a migration — it is a second provider alongside the first,
 * selected per organization.
 *
 * Scope: fees, charge initiation, refunds, webhook verification. Account
 * onboarding is deliberately NOT here — Stripe Connect Express and an
 * Authorize.net merchant account share no meaningful shape, and pretending
 * otherwise would produce an abstraction that fits neither.
 */

export type PaymentProviderName = "stripe" | "authorize_net"

export type FeeMode = "absorb" | "pass_to_buyer" | "registrant_choice"

export type FeeBreakdown = {
  /** Platform's cut. Zero for providers where funds never pass through us. */
  serviceFee: number
  /** The processor's cost.  */
  processingFee: number
  /** What the buyer is charged in total. */
  total: number
  /** What the platform collects from the charge, where the provider supports it. */
  applicationFee: number
}

/**
 * Card data tokenized in the browser by Accept.js. The raw PAN goes from the
 * registrant's browser straight to Authorize.net and never reaches our server
 * — that is the whole PCI-scope argument, so nothing here may ever be widened
 * to carry a card number.
 */
export type PaymentNonce = {
  descriptor: string
  value: string
}

export type ChargeInput = {
  orgId: string
  eventSlug: string
  /** Registrant name, needed by Authorize.net's billTo. */
  firstName?: string
  lastName?: string
  /** Required by providers that charge synchronously; ignored by Stripe. */
  nonce?: PaymentNonce
  /** Human-readable label for the ticket line, e.g. "5K — Early Bird". */
  description: string
  /** Ticket price after any promo discount, before fees. */
  ticketCents: number
  /** Present only when fees are being passed to the buyer. */
  fees: FeeBreakdown | null
  /** What the platform takes from the charge. Ignored by providers without splits. */
  applicationFeeCents: number
  /** Stripe Connect destination. Null for providers that settle directly to the merchant. */
  destinationAccountId: string | null
  customerEmail: string
  successUrl: string
  cancelUrl: string
  /** Carried through the provider and returned on the completion event. */
  metadata: Record<string, string>
  /**
   * Close the hosted checkout after this many minutes (Stripe minimum 30).
   * Used for capacity-limited deposit events so a seat isn't held open by an
   * abandoned tab. Omitted = the provider's default (24 hours on Stripe).
   */
  expiresInMinutes?: number
}

export type FeeOptions = {
  /** No platform service fee on this charge (events.waive_platform_fee). */
  waivePlatformFee?: boolean
}

/**
 * Providers begin a charge in genuinely different shapes, and flattening that
 * difference would be a lie:
 *
 *   Stripe Checkout  — redirect away, complete asynchronously via webhook.
 *   Authorize.net    — Accept.js tokenizes in the browser, we charge
 *                      server-side and know the outcome in the same request.
 *
 * The synchronous case is strictly better for anything that claims a limited
 * resource (a seat, a shirt), because the registrant is still present to be
 * told "that tier just closed".
 */
export type CheckoutStart =
  | { kind: "redirect"; url: string }
  | {
      kind: "completed"
      paymentReference: string
      amountChargedCents: number
      /** Masked card tail, retained because Authorize.net refunds require it. */
      accountLast4: string | null
    }
  | { kind: "error"; message: string }

export type RefundInput = {
  /** Provider-side payment identifier (Stripe PaymentIntent id, or AN transaction id). */
  paymentReference: string
  /** Omit for a full refund. */
  amountCents?: number
  /**
   * Last four digits of the charged card. Authorize.net's refundTransaction
   * rejects the request without it; Stripe ignores it.
   */
  accountLast4?: string | null
  /**
   * Stripe destination charges only: pull the refunded amount back from the
   * connected account instead of the platform balance. Used by per-payment
   * refunds on deposit events; the original full-refund path doesn't set it.
   */
  reverseTransfer?: boolean
}

export type RefundResult =
  | { ok: true; refundReference: string }
  | { ok: false; error: string }

/** Normalized webhook events. Anything we don't act on collapses to "ignored". */
export type ProviderWebhookEvent =
  | {
      kind: "payment_completed"
      /** Provider's own event id, for replay dedupe. */
      eventId: string | null
      paymentReference: string | null
      amountTotalCents: number | null
      metadata: Record<string, string>
    }
  | {
      /**
       * A refund or void issued outside EventHaven — typically from the
       * processor's own dashboard. Without handling this, someone refunded by
       * the organizer still shows as registered and still holds their seat.
       */
      kind: "payment_refunded"
      eventId: string | null
      paymentReference: string | null
      /** Cumulative amount refunded on the charge, when the provider reports it. */
      amountRefundedCents?: number | null
    }
  | { kind: "ignored" }

export type PaymentProvider = {
  readonly name: PaymentProviderName

  /**
   * Pure and synchronous by design — it is called during server rendering to
   * show a fee preview, and making it async would force those call sites to
   * change shape for no benefit.
   */
  calculateFees(ticketCents: number, options?: FeeOptions): FeeBreakdown
  /** The processor's own estimated cost on a charge, used in absorb mode. */
  estimateProcessingFee(amountCents: number): number

  beginCheckout(input: ChargeInput): Promise<CheckoutStart>
  refund(input: RefundInput): Promise<RefundResult>
  /** Returns null when the signature does not verify. */
  verifyWebhook(rawBody: string, headers: Headers): Promise<ProviderWebhookEvent | null>
}
