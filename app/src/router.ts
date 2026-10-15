import {createRouter,createWebHashHistory} from 'vue-router';
import {session} from './services/session';

const routes=[
 {path:'/',redirect:'/dashboard'},
 {path:'/dashboard',name:'dashboard',component:()=>import('./views/Dashboard.vue')},
 {path:'/courses',name:'courses',component:()=>import('./views/Courses.vue')},
 {path:'/people',name:'people',component:()=>import('./views/People.vue')},
 {path:'/assignments',name:'assignments',component:()=>import('./views/Assignments.vue')},
 {path:'/notices',name:'notices',component:()=>import('./views/Notices.vue')},
 {path:'/grades',name:'grades',component:()=>import('./views/Grades.vue')},
 {path:'/security',name:'security',component:()=>import('./views/Security.vue')},
 {path:'/:pathMatch(.*)*',redirect:'/dashboard'}
];
const router=createRouter({history:createWebHashHistory(import.meta.env.BASE_URL),routes});
router.beforeEach(to=>{
 if(session.ready && session.role==='student' && ['people','grades','security'].includes(String(to.name)))return '/dashboard';
});
export default router;
