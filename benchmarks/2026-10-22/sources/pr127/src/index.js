import http from 'node:http';
import { healthRoute } from './routes/health.js';
import { feedRoute } from './routes/feed.js';
import { getPostById, createPost, likePost } from './routes/posts.js';
const HOST = process.env.HOST ?? '127.0.0.1';
const PORT = Number(process.env.PORT ?? 3000);

let memoryUsageLogIntevalID;

const server = http.createServer({
        keepAlive: true,
        highWaterMark: 4 * 1024, //8kb buffer for reading and writing instead of default 16kb
        headersTimeout: 10_000,
        keepAliveTimeout: 70_000,
        requestTimeout: 30_000,
        connectionsCheckingInterval: 30_000,
        noDelay: true
    },

    async (req, res) => {

        try {
                const { method, url } = req;

                if (method === 'GET') {

                    if (url === '/health') {
                        return healthRoute(req, res);
                    }

                    else if (url === '/feed') {
                        return feedRoute(req, res);
                    }

                    else if (url?.startsWith('/posts/')) {
                        return getPostById(req, res, url.split('/')[2]);
                    }

                }

                else if (method === 'POST') {

                    if (url === '/posts') {
                        return createPost(req, res);
                    }

                    else if (
                        url?.startsWith('/posts/') &&
                        url.endsWith('/like')
                    ) {
                        return likePost(req, res, url.split('/')[2]);
                    }
                }

                res.statusCode = 404;
                res.setHeader('Content-Type', 'application/json');
                res.end('{"error":"not found"}');
            } 
            
        catch {
            res.statusCode = 500;
            res.setHeader('Content-Type', 'application/json');
            res.end('{"error":"internal server error"}');
        }
    })
    
    .listen(PORT, HOST, () => {

        memoryUsageLogIntevalID = setInterval(() => {

        const { rss, heapUsed, heapTotal, external } = process.memoryUsage();

        console.clear();
        
        process.stdout.write(
            '\r' +
            `[MEM] rss=${Math.round(rss / 1024 / 1024)}MB | ` +
            `heap used=${Math.round(heapUsed / 1024 / 1024)}/${Math.round(heapTotal / 1024 / 1024)}MB | ` +
            `ext=${Math.round(external / 1024 / 1024)}MB |` +
            ` total heap=${Math.round(heapTotal / 1024 / 1024)}MB`
        );

        }, 1000);

        console.log(`Server is running at http://${HOST}:${PORT}`);

    });


    function shutdown () {
        console.log("SERVER WILL BE SHUTDOWN NOW. THANKS FOR THE CHALLENGE!");
        clearInterval(memoryUsageLogIntevalID);

        server.close();
        process.exit(0);
        
    }   

    process.on(
        'SIGINT',
        () => shutdown('SIGINT')
    );

    process.on(
        'SIGTERM',
        () => shutdown('SIGTERM')
    );