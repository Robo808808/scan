// Uses fixed inputs and only changes the database - Running it twice gives the same result

Connection conn = dataSource.getConnection();
conn.setAutoCommit(false);

PreparedStatement ps = conn.prepareStatement(
    "INSERT INTO products (product_id, name, price) VALUES (?, ?, ?)"
);
ps.setInt(1, 1001);
ps.setString(2, "Keyboard");
ps.setBigDecimal(3, new BigDecimal("49.99"));

ps.executeUpdate();
conn.commit();
conn.close();


// Uses timestamps, sequences, UUIDs, random values - Running twice gives different results
Connection conn = dataSource.getConnection();
conn.setAutoCommit(false);

PreparedStatement ps = conn.prepareStatement(
    "INSERT INTO orders (order_id, created_at) VALUES (orders_seq.nextval, SYSDATE)"
);

ps.executeUpdate();
conn.commit();
conn.close();


// Calls external systems (files, web calls, emails, messages) - Replay would duplicate side-effects
// Insert a record AND send an email
conn.setAutoCommit(false);
ps.executeUpdate();

// Publish message to external system
emailService.send("Order Received");  // <- This cannot be undone or repeated safely

conn.commit();
