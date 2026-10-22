package tds.challenge.db;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.Spliterator;
import java.util.Spliterators;
import java.util.function.Consumer;
import java.util.stream.Stream;
import java.util.stream.StreamSupport;

@FunctionalInterface
public interface RowMapper<T> {

    T map(ResultSet rs) throws SQLException;

    static <T> Stream<T> stream(ResultSet rs, RowMapper<T> mapper) {
        Spliterator<T> spliterator = new Spliterators.AbstractSpliterator<>(
                Long.MAX_VALUE, Spliterator.ORDERED | Spliterator.NONNULL) {
            @Override
            public boolean tryAdvance(Consumer<? super T> action) {
                try {
                    if (!rs.next()) {
                        return false;
                    }
                    action.accept(mapper.map(rs));
                    return true;
                } catch (SQLException e) {
                    throw new UncheckedSQLException(e);
                }
            }
        };
        return StreamSupport.stream(spliterator, false);   // false: ResultSet is not thread-safe
    }
}
