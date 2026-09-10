import {
  z,
} from 'zod';

const MAX_MONEY_MINOR =
  9_999_999_999;

export const commercialQuoteItemSchema =
  z.object({
    /**
     * Existing ServiceOrderItem IDs are preserved when supplied.
     * Omit id only for a new item.
     */
    id:
      z.string()
        .uuid()
        .optional(),

    partId:
      z.string()
        .uuid()
        .nullable()
        .optional(),

    description:
      z.string()
        .trim()
        .min(1)
        .max(1000),

    quantity:
      z.number()
        .int()
        .min(1)
        .max(100_000),

    unitPriceMinor:
      z.number()
        .int()
        .min(0)
        .max(
          MAX_MONEY_MINOR
        ),
  })
    .strict();

export const publishCommercialQuoteRevisionSchema =
  z.object({
    diagnosis:
      z.string()
        .trim()
        .min(1)
        .max(20_000)
        .nullable(),

    items:
      z.array(
        commercialQuoteItemSchema
      )
        .min(1)
        .max(200),

    changeReason:
      z.string()
        .trim()
        .min(1)
        .max(1000),
  })
    .strict();

export type PublishCommercialQuoteRevisionInput =
  z.infer<
    typeof publishCommercialQuoteRevisionSchema
  >;

export type CommercialQuoteItemInput =
  z.infer<
    typeof commercialQuoteItemSchema
  >;
