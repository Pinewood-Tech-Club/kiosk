CREATE UNIQUE INDEX orders_square_payment ON orders (square_payment_id) WHERE square_payment_id IS NOT NULL;
