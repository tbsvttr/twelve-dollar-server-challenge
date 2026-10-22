package tds.challenge.db;

import java.sql.SQLException;

/**
 * Streams checked SQLExceptions out as unchecked ones.
 * Unwrap at the call site, or don't I don't judge!
 */
public final class UncheckedSQLException extends RuntimeException {
    public UncheckedSQLException(SQLException cause) {
        super(cause);
    }

    @Override
    public SQLException getCause() {
        return (SQLException) super.getCause();
    }
}